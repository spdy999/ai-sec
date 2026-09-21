"""Build the corpus index. Run by an operator, never by the service.

The running service has read-only access to this index: the OpenSearch data
access policy grants writes to the jump host role only. That is what stops a
prompt injection poisoning the corpus -- not a check in the code, which the
injection would be trying to reach anyway, but the absence of the permission.

    python -m mediation.ingest \
      --bucket genai-assistant-prod-rag-XXXX \
      --endpoint https://xxxx.eu-central-1.aoss.amazonaws.com

Each document's audience comes from its own `Audience:` header. A document with
no header is indexed as all-staff, which is the safe default only because every
restricted document in this corpus states its audience explicitly -- a fact the
--strict flag will verify rather than assume.
"""

import argparse
import json
import re
import sys

import boto3
from opensearchpy import AWSV4SignerAuth, OpenSearch, RequestsHttpConnection

AUDIENCE = re.compile(r"^Audience:\s*(.+)$", re.MULTILINE)

# Chunks are whole paragraphs. Splitting on a token count cuts sentences in half
# and produces passages that read as if the document said something it did not.
PARAGRAPH = re.compile(r"\n\s*\n")

MAPPING = {
    "settings": {"index": {"knn": True}},
    "mappings": {
        "properties": {
            "embedding": {
                "type": "knn_vector",
                "dimension": 1024,
                "method": {"name": "hnsw", "engine": "faiss", "space_type": "l2"},
            },
            "text": {"type": "text"},
            "document": {"type": "keyword"},
            # Keyword, not text. Analysed as text, "finance-team" matches
            # "finance" and the entitlement filter stops meaning anything.
            "allowed_groups": {"type": "keyword"},
        }
    },
}


def audience_of(body: str) -> list[str]:
    match = AUDIENCE.search(body)
    if not match:
        return ["all-staff"]
    return [group.strip() for group in match.group(1).split(",") if group.strip()]


def chunks(body: str, minimum: int = 120) -> list[str]:
    paragraphs = [p.strip() for p in PARAGRAPH.split(body) if p.strip()]

    merged: list[str] = []
    for paragraph in paragraphs:
        if merged and len(merged[-1]) < minimum:
            merged[-1] = f"{merged[-1]}\n\n{paragraph}"
        else:
            merged.append(paragraph)
    return merged


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--region", default="eu-central-1")
    parser.add_argument("--index", default="genai-corpus")
    parser.add_argument("--prefix", default="corpus/")
    parser.add_argument("--embedding-model", default="amazon.titan-embed-text-v2:0")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="fail if any document carries no Audience header, rather than defaulting it to all-staff",
    )
    parser.add_argument("--recreate", action="store_true", help="delete the index first")
    args = parser.parse_args()

    session = boto3.Session(region_name=args.region)
    s3 = session.client("s3")
    bedrock = session.client("bedrock-runtime")

    client = OpenSearch(
        hosts=[{"host": args.endpoint.replace("https://", ""), "port": 443}],
        http_auth=AWSV4SignerAuth(session.get_credentials(), args.region, "aoss"),
        use_ssl=True,
        verify_certs=True,
        connection_class=RequestsHttpConnection,
    )

    if args.recreate and client.indices.exists(index=args.index):
        client.indices.delete(index=args.index)
    if not client.indices.exists(index=args.index):
        client.indices.create(index=args.index, body=MAPPING)

    keys = [
        obj["Key"]
        for page in s3.get_paginator("list_objects_v2").paginate(
            Bucket=args.bucket, Prefix=args.prefix
        )
        for obj in page.get("Contents", [])
        if obj["Key"].endswith(".md")
    ]

    if not keys:
        sys.exit(f"no documents under s3://{args.bucket}/{args.prefix}")

    indexed = 0
    for key in sorted(keys):
        body = s3.get_object(Bucket=args.bucket, Key=key)["Body"].read().decode("utf-8")
        name = key.rsplit("/", 1)[-1]

        if args.strict and not AUDIENCE.search(body):
            sys.exit(f"{name} carries no Audience header and --strict is set")

        groups = audience_of(body)

        for position, chunk in enumerate(chunks(body)):
            vector = json.loads(
                bedrock.invoke_model(
                    modelId=args.embedding_model,
                    body=json.dumps({"inputText": chunk}),
                )["body"].read()
            )["embedding"]

            client.index(
                index=args.index,
                body={
                    "document": name,
                    "text": chunk,
                    "allowed_groups": groups,
                    "embedding": vector,
                },
            )
            indexed += 1

        print(f"{name}: {len(chunks(body))} passages, audience {', '.join(groups)}")

    print(f"\nindexed {indexed} passages from {len(keys)} documents into {args.index}")


if __name__ == "__main__":
    main()

"""Build the corpus index. Run by an operator, never by the service.

The running service has read-only access to this index. Under Bedrock that is
the OpenSearch Serverless data access policy granting writes to the jump host
role only; under the local runtime it is an OpenSearch role granting the service
user `read` and nothing more. Either way it is what stops a prompt injection
poisoning the corpus -- not a check in the code, which the injection would be
trying to reach anyway, but the absence of the permission.

    # the deployed platform
    python -m mediation.ingest --provider bedrock \
      --bucket genai-assistant-rag-documents-prod \
      --endpoint https://xxxx.eu-central-1.aoss.amazonaws.com

    # the local runtime
    python -m mediation.ingest --provider local \
      --source-dir controls/data/corpus \
      --endpoint http://localhost:9200

Each document's audience comes from its own `Audience:` header. A document with
no header is indexed as all-staff, which is the safe default only because every
restricted document in this corpus states its audience explicitly -- a fact the
--strict flag will verify rather than assume.
"""

import argparse
import json
import os
import pathlib
import re
import sys

AUDIENCE = re.compile(r"^Audience:\s*(.+)$", re.MULTILINE)

# Chunks are whole paragraphs. Splitting on a token count cuts sentences in half
# and produces passages that read as if the document said something it did not.
PARAGRAPH = re.compile(r"\n\s*\n")

# Embedding width is a property of the model, and the index mapping has to agree
# with it exactly. Titan v2 emits 1024 floats; nomic-embed-text emits 768. An
# index built for one and written by the other fails at write time with a
# dimension error, which is the good outcome -- silently truncating would give a
# working search that returns nonsense.
DIMENSIONS = {
    "amazon.titan-embed-text-v2:0": 1024,
    "nomic-embed-text": 768,
    "nomic-embed-text:latest": 768,
}


def mapping(dimension: int, engine: str) -> dict:
    return {
        "settings": {"index": {"knn": True}},
        "mappings": {
            "properties": {
                "embedding": {
                    "type": "knn_vector",
                    "dimension": dimension,
                    "method": {"name": "hnsw", "engine": engine, "space_type": "l2"},
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


def bedrock_backend(args):
    """S3 for documents, Bedrock for embeddings, AOSS signed with SigV4."""
    import boto3
    from opensearchpy import AWSV4SignerAuth, OpenSearch, RequestsHttpConnection

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

    def documents():
        keys = [
            obj["Key"]
            for page in s3.get_paginator("list_objects_v2").paginate(
                Bucket=args.bucket, Prefix=args.prefix
            )
            for obj in page.get("Contents", [])
            if obj["Key"].endswith(".md")
        ]
        for key in sorted(keys):
            body = s3.get_object(Bucket=args.bucket, Key=key)["Body"].read()
            yield key.rsplit("/", 1)[-1], body.decode("utf-8")

    def embed(text: str) -> list[float]:
        return json.loads(
            bedrock.invoke_model(
                modelId=args.embedding_model,
                body=json.dumps({"inputText": text}),
            )["body"].read()
        )["embedding"]

    return client, documents, embed


def local_backend(args):
    """Files on disk, Ollama for embeddings, OpenSearch with a write-capable user.

    The credentials here are the ingestion user's, deliberately not the
    service's. Running this with the service's credentials is refused by
    OpenSearch, which is the control working rather than a message about it.
    """
    import requests
    from opensearchpy import OpenSearch

    host, _, port = args.endpoint.replace("https://", "").replace("http://", "").partition(":")

    client = OpenSearch(
        hosts=[{"host": host, "port": int(port or 9200)}],
        http_auth=(args.username, args.password),
        use_ssl=args.endpoint.startswith("https://"),
        verify_certs=False,
        ssl_show_warn=False,
    )

    root = pathlib.Path(args.source_dir)

    def documents():
        # README.md describes the corpus; it is not part of it. Indexing it
        # would put a document about the test fixtures into the retrieval path.
        for path in sorted(root.glob("*.md")):
            if path.name == "README.md":
                continue
            yield path.name, path.read_text(encoding="utf-8")

    def embed(text: str) -> list[float]:
        response = requests.post(
            f"{args.ollama.rstrip('/')}/api/embeddings",
            json={"model": args.embedding_model, "prompt": text},
            timeout=120,
        )
        response.raise_for_status()
        return response.json()["embedding"]

    return client, documents, embed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", choices=["bedrock", "local"], default="bedrock")
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--index", default="genai-corpus")
    parser.add_argument("--embedding-model")
    parser.add_argument("--knn-engine", default="")

    # bedrock
    parser.add_argument("--bucket")
    parser.add_argument("--region", default="eu-central-1")
    parser.add_argument("--prefix", default="corpus/")

    # local
    parser.add_argument("--source-dir", default="controls/data/corpus")
    parser.add_argument("--ollama", default=os.environ.get("OLLAMA_ENDPOINT", "http://localhost:11434"))
    parser.add_argument("--username", default=os.environ.get("VECTOR_INGEST_USERNAME", "admin"))
    parser.add_argument("--password", default=os.environ.get("VECTOR_INGEST_PASSWORD", ""))

    parser.add_argument(
        "--strict",
        action="store_true",
        help="fail if any document carries no Audience header, rather than defaulting it to all-staff",
    )
    parser.add_argument("--recreate", action="store_true", help="delete the index first")
    args = parser.parse_args()

    if args.provider == "bedrock":
        args.embedding_model = args.embedding_model or "amazon.titan-embed-text-v2:0"
        args.knn_engine = args.knn_engine or "faiss"
        if not args.bucket:
            sys.exit("--bucket is required with --provider bedrock")
        client, documents, embed = bedrock_backend(args)
    else:
        args.embedding_model = args.embedding_model or "nomic-embed-text"
        # lucene rather than faiss: the engine ships in every OpenSearch build,
        # so the local index does not depend on which k-NN libraries the
        # container image happened to be compiled with.
        args.knn_engine = args.knn_engine or "lucene"
        if not args.password:
            sys.exit("--password or VECTOR_INGEST_PASSWORD is required with --provider local")
        client, documents, embed = local_backend(args)

    dimension = DIMENSIONS.get(args.embedding_model)
    if dimension is None:
        sys.exit(
            f"unknown embedding width for {args.embedding_model!r}; "
            f"add it to DIMENSIONS rather than guessing"
        )

    if args.recreate and client.indices.exists(index=args.index):
        client.indices.delete(index=args.index)
    if not client.indices.exists(index=args.index):
        client.indices.create(index=args.index, body=mapping(dimension, args.knn_engine))

    indexed = 0
    seen = 0
    for name, body in documents():
        seen += 1

        if args.strict and not AUDIENCE.search(body):
            sys.exit(f"{name} carries no Audience header and --strict is set")

        groups = audience_of(body)
        passages = chunks(body)

        for chunk in passages:
            client.index(
                index=args.index,
                body={
                    "document": name,
                    "text": chunk,
                    "allowed_groups": groups,
                    "embedding": embed(chunk),
                },
            )
            indexed += 1

        print(f"{name}: {len(passages)} passages, audience {', '.join(groups)}")

    if not seen:
        sys.exit("no documents found; nothing was indexed")

    client.indices.refresh(index=args.index)
    print(f"\nindexed {indexed} passages from {seen} documents into {args.index}")


if __name__ == "__main__":
    main()

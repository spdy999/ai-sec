"""Entitlement-filtered vector search.

The filter is part of the query, not a pass over the results. Retrieving a
restricted passage and dropping it afterwards still means the process read it,
the vector store logged the read, and any bug between those two points leaks it.
"""

import json

from . import config, providers


def embed(text: str) -> list[float]:
    return providers.embed(text)


def search(question: str, groups: frozenset[str], top_k: int | None = None) -> list[dict]:
    """Nearest passages the caller is entitled to see.

    `allowed_groups` is a keyword field on every indexed chunk. The terms filter
    runs inside the kNN query, so a passage the caller cannot see is never a
    candidate in the first place.
    """
    client = providers.vector_client()

    query = {
        "size": top_k or config.TOP_K,
        "_source": ["text", "document", "allowed_groups"],
        "query": {
            "bool": {
                "filter": [{"terms": {"allowed_groups": sorted(groups)}}],
                "must": [
                    {
                        "knn": {
                            "embedding": {
                                "vector": embed(question),
                                "k": top_k or config.TOP_K,
                            }
                        }
                    }
                ],
            }
        },
    }

    hits = client.search(index=config.VECTOR_INDEX, body=query)["hits"]["hits"]

    return [
        {
            "document": hit["_source"]["document"],
            "text": hit["_source"]["text"],
            "score": hit["_score"],
        }
        for hit in hits
    ]

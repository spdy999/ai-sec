# vector-store

OpenSearch Serverless collection holding the document embeddings the assistant
searches at question time.

This is the component people forget to secure, because it looks like a cache
rather than a copy of the data. It is a copy of the data. Anything the corpus
contains is reachable through vector search.

Two policies make it private:

- the **encryption policy** pins the collection to the CMK instead of the
  AWS-owned key, so key use is auditable and revocable;
- the **network policy** sets `AllowFromPublic = false` and names the VPC
  endpoint as the only source.

Access control on retrieval belongs a layer up, in the mediation service: the
filter that decides which documents a given user's search may return at all.

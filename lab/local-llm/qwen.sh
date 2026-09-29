# 1. Pull your chat model
ollama pull qwen3.5:4b

# 2. Pull the embedding model (required for RAG)
ollama pull nomic-embed-text

docker compose up -d

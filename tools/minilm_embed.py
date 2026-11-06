#!/usr/bin/env python3
"""Real neural embedding via MiniLM ONNX (ONNX Runtime).
Usage: minilm_embed.py <model.onnx> <vocab.txt> "<text>"
Prints JSON {"vector":[...], "dim":384}
WordPiece tokenizer (BERT vocab) + mean pooling, mirrors transformers.js.
"""
import sys, json
import numpy as np
import onnxruntime as ort

def wordpiece(token, vocab, unk="[UNK]"):
    chars = list(token)
    if len(chars) == 0:
        return []
    out = []
    start = 0
    while start < len(chars):
        end = len(chars)
        cur = None
        while start < end:
            substr = "".join(chars[start:end])
            if start > 0:
                substr = "##" + substr
            if substr in vocab:
                cur = substr
                break
            end -= 1
        if cur is None:
            return [unk]
        out.append(cur)
        start = end
    return out

def main():
    model_path, vocab_path, text = sys.argv[1], sys.argv[2], sys.argv[3]
    vocab = {}
    with open(vocab_path, encoding="utf-8") as f:
        for i, line in enumerate(f):
            vocab[line.strip()] = i
    # Tokenize: [CLS] + wordpieces + [SEP], max 256
    tokens = ["[CLS]"]
    for w in text.lower().split():
        tokens.extend(wordpiece(w, vocab))
    tokens.append("[SEP]")
    tokens = tokens[:256]
    input_ids = np.array([[vocab.get(t, 0) for t in tokens]], dtype=np.int64)
    attn = np.ones_like(input_ids)
    sess = ort.InferenceSession(model_path, providers=["CPUExecutionProvider"])
    feed = {sess.get_inputs()[0].name: input_ids, sess.get_inputs()[1].name: attn}
    # Some models need token_type_ids
    names = [i.name for i in sess.get_inputs()]
    if "token_type_ids" in names:
        feed["token_type_ids"] = np.zeros_like(input_ids)
    out = sess.run(None, feed)[0]
    # Mean pooling over attention mask
    mask = attn.astype(np.float32)[:, :, None]
    summed = (out * mask).sum(axis=1)
    counts = np.clip(mask.sum(axis=1), 1e-9, None)
    emb = summed / counts
    # Normalize (MiniLM pooling module normalizes)
    norm = np.linalg.norm(emb, axis=1, keepdims=True)
    emb = emb / np.clip(norm, 1e-9, None)
    print(json.dumps({"vector": emb[0].tolist(), "dim": int(emb.shape[1])}))

if __name__ == "__main__":
    main()

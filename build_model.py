#!/usr/bin/env python3 -I
"""build_model.py: per-language word list and character n-gram model for detect.swift.

Source: wordfreq 3.1.1 large lists (rspeer; Wikipedia, OpenSubtitles 2018, news, Google Books,
OSCAR web, Twitter, Reddit, by language), data under CC BY-SA 4.0, so the files written here carry CC BY-SA 4.0 with attribution (data/LICENSE).
Usage: build_model.py VOCAB_SIZE ORDER MIN_PER_BILLION -> data/<lang>.words, data/<lang>.ngram

.words: "word\tlog10p", the VOCAB_SIZE commonest words, sorted by UTF-8 bytes (log10 of the word's share of all tokens).
.ngram: Witten-Bell interpolated char model, one line per seen n-gram:
        "ctx\tchar\tlog10p" plus "ctx\t\tlog10gamma" for each context (the back-off mass);
        "^" pads the start, "$" ends a word. Witten-Bell because counts are fractional
        (each word type is weighted by log2(1+per-billion count), so morphology counts, not just the
        hundred commonest words).
"""
import math, re, sys, unicodedata
from collections import defaultdict
from pathlib import Path

D = Path(__file__).resolve().parent / "data"
VOCAB = int(sys.argv[1]) if len(sys.argv) > 1 else 100000
ORDER = int(sys.argv[2]) if len(sys.argv) > 2 else 4
MINC = int(sys.argv[3]) if len(sys.argv) > 3 else 3
TRAIN_TYPES = 300000

ALPHA = {"en": "abcdefghijklmnopqrstuvwxyz'",
         "ru": "абвгдежзийклмнопрстуфхцчшщъыьэюя",
         "uk": "абвгґдеєжзиіїйклмнопрстуфхцчшщьюяʼ"}

def norm(w, lang):
    w = unicodedata.normalize("NFC", w.lower())
    if lang == "ru": w = w.replace("ё", "е")
    if lang == "uk": w = w.replace("'", "ʼ").replace("’", "ʼ")
    if lang == "en": w = w.replace("’", "'")
    return w

RAW = {}
for lang in ("en", "ru", "uk"):
    alpha = set(ALPHA[lang]); apo = "ʼ" if lang == "uk" else "'"
    counts = defaultdict(float)
    for line in open(D / "src" / f"wf_{lang}.txt", encoding="utf-8"):
        p = line.rstrip("\n").split("\t")
        w, c = norm(p[0], lang), 10 ** float(p[1]) * 1e9   # per billion words
        if c < MINC or not w or not set(w) <= alpha: continue
        if w[0] == apo or w[-1] == apo: continue
        counts[w] += c
    RAW[lang] = counts
# Russian and Ukrainian web text is mixed: the uk list holds «что», «привет», «сейчас» high up,
# which made Russian words typed right look Ukrainian. A word ten times commoner in the other
# Cyrillic list is taken as that language's and dropped here (shared words like «не», «так» stay).
CROSS = 10.0
DROP = {a: {w for w, c in RAW[a].items() if RAW[b].get(w, 0) > CROSS * c} for a, b in (("uk", "ru"), ("ru", "uk"))}
for a in DROP:
    for w in DROP[a]: del RAW[a][w]
print("cross-dropped", {a: len(x) for a, x in DROP.items()})
for lang in ("en", "ru", "uk"):
    alpha = set(ALPHA[lang])
    counts = RAW[lang]
    items = sorted(counts.items(), key=lambda x: -x[1])
    total = sum(c for _, c in items)
    # sorted by UTF-8 bytes, so detect.swift can binary-search one byte buffer (no per-word objects)
    with open(D / f"{lang}.words", "w") as f:
        for w, c in sorted(items[:VOCAB], key=lambda x: x[0].encode("utf-8")):
            f.write(f"{w}\t{math.log10(c / total):.2f}\n")
    # char model
    N = [defaultdict(float) for _ in range(ORDER)]          # N[k][(ctx,c)] with len(ctx)=k
    for w, c in items[:TRAIN_TYPES]:
        wt = math.log2(1 + c)
        s = "^" * (ORDER - 1) + w + "$"
        for i in range(ORDER - 1, len(s)):
            for k in range(ORDER):
                N[k][(s[i - k:i], s[i])] += wt
    vocab_size = len(alpha) + 1
    ctx_tot = [defaultdict(float) for _ in range(ORDER)]; ctx_T = [defaultdict(int) for _ in range(ORDER)]
    for k in range(ORDER):
        for (h, c), n in N[k].items(): ctx_tot[k][h] += n; ctx_T[k][h] += 1
    P = {}  # (h,c) -> prob, built from low order up
    def prob(h, c):
        k = len(h)
        if k < 0: return 1.0 / vocab_size
        if (h, c) in P: return P[(h, c)]
        lower = prob(h[1:], c) if k > 0 else 1.0 / vocab_size
        if h not in ctx_tot[k]: return lower
        n, T = ctx_tot[k][h], ctx_T[k][h]
        return T / (n + T) * lower
    for k in range(ORDER):
        for (h, c), n in N[k].items():
            lower = prob(h[1:], c) if k > 0 else 1.0 / vocab_size
            P[(h, c)] = (n + ctx_T[k][h] * lower) / (ctx_tot[k][h] + ctx_T[k][h])
    with open(D / f"{lang}.ngram", "w") as f:
        for k in range(ORDER):
            for h in ctx_tot[k]:
                f.write(f"{h}\t\t{math.log10(ctx_T[k][h] / (ctx_tot[k][h] + ctx_T[k][h])):.4f}\n")
            for (h, c) in N[k]:
                f.write(f"{h}\t{c}\t{math.log10(P[(h, c)]):.4f}\n")
    print(lang, "types", len(items), "kept", min(VOCAB, len(items)), "tokens", total,
          "ngrams", sum(len(x) for x in N), "words KB", (D / f"{lang}.words").stat().st_size // 1024,
          "ngram KB", (D / f"{lang}.ngram").stat().st_size // 1024)

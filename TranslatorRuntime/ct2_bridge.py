#!/usr/bin/env python3
# Bundled offline PDF translator: CTranslate2 + PyMuPDF.
# Protocol: one JSON object per stdin line -> one JSON object per stdout line.

from __future__ import annotations

import base64
import json
import os
import re
import shutil
import sys
import tempfile
import traceback
import urllib.error
import urllib.request
from pathlib import Path

import ctranslate2
import fitz  # PyMuPDF
import sentencepiece as spm


ROOT = Path(__file__).resolve().parent
CATALOG_PATH = ROOT / "model_catalog.json"
# Writable cache (Application Support). Falls back to runtime models/ for dev.
MODELS_DIR = Path(
    os.environ.get("PDF_TRANSLATOR_MODELS_DIR") or (ROOT / "models")
).expanduser()

_translators = {}
_tokenizers = {}
_target_prefixes = {}
_catalog_cache: dict | None = None

_LETTER_RE = re.compile(r"[^\W\d_]", re.UNICODE)
# Marian-style target language codes present in some Opus-MT vocabularies.
_TARGET_LANG_TOKENS = {
    "zh": (">>cmn_Hans<<", ">>zh<<", ">>zho<<", ">>cmn<<"),
    "ja": (">>jpn<<", ">>ja<<"),
    "ko": (">>kor<<", ">>ko<<"),
    "en": (">>eng<<", ">>en<<"),
    "es": (">>spa<<", ">>es<<"),
    "fr": (">>fra<<", ">>fr<<"),
    "de": (">>deu<<", ">>de<<"),
    "it": (">>ita<<", ">>it<<"),
    "ru": (">>rus<<", ">>ru<<"),
}
_CHECKBOX_RE = re.compile(
    r"^[\s☐☑☒□■▢▣✓✔✕✗✘○●◻◼▫▪\[\]\(\)\u2610\u2611\u2612]+$"
)
_MODEL_REQUIRED_FILES = ("model.bin", "config.json", "shared_vocabulary.json")
_MODEL_SOURCE_SPM = ("source.spm", "sentencepiece.model", "spm.model")
_MODEL_OPTIONAL_FILES = ("target.spm",)


def _reply(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _progress(detail: str) -> None:
    _reply({"ok": True, "event": "progress", "detail": detail})


def _normalize(code: str) -> str:
    code = (code or "").replace("_", "-").lower()
    if code.startswith("zh"):
        return "zh"
    if "-" in code:
        return code.split("-", 1)[0]
    return code


def _pair_dir(from_code: str, to_code: str) -> Path:
    return MODELS_DIR / f"{from_code}-{to_code}"


def os_cpu_count():
    return os.cpu_count()


def _load_catalog() -> dict:
    global _catalog_cache
    if _catalog_cache is not None:
        return _catalog_cache
    if not CATALOG_PATH.exists():
        raise RuntimeError(f"Model catalog missing: {CATALOG_PATH}")
    _catalog_cache = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    return _catalog_cache


def _catalog_pair(from_code: str, to_code: str) -> dict | None:
    key = f"{from_code}-{to_code}"
    for pair in _load_catalog().get("pairs", []):
        if f"{pair.get('from')}-{pair.get('to')}" == key:
            return pair
    return None


def _model_ready(model_dir: Path) -> bool:
    if not model_dir.is_dir():
        return False
    if not all((model_dir / name).exists() for name in _MODEL_REQUIRED_FILES):
        return False
    return any((model_dir / name).exists() for name in _MODEL_SOURCE_SPM)


def _find_spm(model_dir: Path, names: tuple[str, ...]) -> Path | None:
    for name in names:
        path = model_dir / name
        if path.exists():
            return path
    return None


def _download_file(url: str, dest: Path, label: str) -> None:
    _progress(label)
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "offline-pdf-translator/1.0"},
    )
    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            with open(dest, "wb") as handle:
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    handle.write(chunk)
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Download failed ({exc.code}): {url}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Network error downloading {url}: {exc.reason}") from exc


def _ensure_model(from_code: str, to_code: str) -> dict:
    """Download the pair from Hugging Face if it is not already installed."""
    pair = _catalog_pair(from_code, to_code)
    if pair is None:
        raise RuntimeError(
            f"No downloadable model for {from_code}->{to_code}. "
            "Pick a supported language pair from the catalog."
        )

    dest = _pair_dir(from_code, to_code)
    if _model_ready(dest):
        return {
            "from": from_code,
            "to": to_code,
            "installed": True,
            "downloaded": False,
            "path": str(dest),
        }

    repo = pair["repo"]
    approx = pair.get("approx_mb", 150)
    base = f"https://huggingface.co/{repo}/resolve/main"
    MODELS_DIR.mkdir(parents=True, exist_ok=True)

    _progress(
        f"Downloading {from_code}→{to_code} (~{approx} MB). Needs internet once…"
    )

    staging = Path(
        tempfile.mkdtemp(prefix=f"offline-pdf-translator-{from_code}-{to_code}-", dir=str(MODELS_DIR))
    )
    try:
        files = [
            ("model.bin", True),
            ("config.json", True),
            ("shared_vocabulary.json", True),
            ("source.spm", True),
            ("target.spm", False),
        ]
        for index, (name, required) in enumerate(files, start=1):
            target = staging / name
            try:
                _download_file(
                    f"{base}/{name}",
                    target,
                    f"Downloading {from_code}→{to_code}: {name} ({index}/{len(files)})…",
                )
            except RuntimeError:
                if name == "source.spm":
                    _download_file(
                        f"{base}/sentencepiece.model",
                        staging / "sentencepiece.model",
                        f"Downloading {from_code}→{to_code}: sentencepiece.model…",
                    )
                    continue
                if required:
                    raise
                # Optional file missing — fine.

        if not _model_ready(staging):
            raise RuntimeError(f"Downloaded model for {from_code}->{to_code} is incomplete.")

        if dest.exists():
            shutil.rmtree(dest)
        staging.rename(dest)
        _progress(f"Installed {from_code}→{to_code} model.")
        return {
            "from": from_code,
            "to": to_code,
            "installed": True,
            "downloaded": True,
            "path": str(dest),
        }
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def _detect_target_prefix(model_dir: Path, to_code: str) -> str | None:
    vocab_path = model_dir / "shared_vocabulary.json"
    if not vocab_path.exists():
        return None
    try:
        vocab = json.loads(vocab_path.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return None
    tokens = set(vocab) if isinstance(vocab, list) else set(vocab)
    for candidate in _TARGET_LANG_TOKENS.get(to_code, ()):
        if candidate in tokens:
            return candidate
    return None


def _load_pair(from_code: str, to_code: str):
    key = f"{from_code}-{to_code}"
    if key in _translators:
        return _translators[key], _tokenizers[key], _target_prefixes.get(key)

    _ensure_model(from_code, to_code)
    model_dir = _pair_dir(from_code, to_code)

    shared = _find_spm(model_dir, ("sentencepiece.model", "spm.model"))
    source_path = shared or _find_spm(model_dir, ("source.spm",))
    target_path = shared or _find_spm(model_dir, ("target.spm", "source.spm"))
    if source_path is None:
        raise RuntimeError(f"Missing sentencepiece model in {model_dir}")

    translator = ctranslate2.Translator(
        str(model_dir),
        device="cpu",
        compute_type="default",
        inter_threads=max(1, (os_cpu_count() or 4) // 2),
        intra_threads=2,
    )
    source_tokenizer = spm.SentencePieceProcessor(model_file=str(source_path))
    target_tokenizer = (
        source_tokenizer
        if target_path == source_path
        else spm.SentencePieceProcessor(model_file=str(target_path))
    )
    prefix = _detect_target_prefix(model_dir, to_code)
    _translators[key] = translator
    _tokenizers[key] = (source_tokenizer, target_tokenizer)
    _target_prefixes[key] = prefix
    return translator, (source_tokenizer, target_tokenizer), prefix


def _list_languages():
    catalog = _load_catalog()
    languages = catalog.get("languages") or []
    if languages:
        return languages
    # Fallback from pairs if languages section is empty.
    codes = set()
    for pair in catalog.get("pairs", []):
        codes.add(pair["from"])
        codes.add(pair["to"])
    return [{"code": c, "name": c.upper()} for c in sorted(codes)]


def _list_catalog():
    catalog = _load_catalog()
    pairs = []
    for pair in catalog.get("pairs", []):
        from_code = pair["from"]
        to_code = pair["to"]
        pairs.append(
            {
                "from": from_code,
                "to": to_code,
                "repo": pair.get("repo"),
                "approx_mb": pair.get("approx_mb", 150),
                "installed": _model_ready(_pair_dir(from_code, to_code)),
            }
        )
    return {
        "languages": _list_languages(),
        "pairs": pairs,
        "models_dir": str(MODELS_DIR),
    }


def _is_checkbox_or_symbol(text: str) -> bool:
    t = (text or "").strip()
    if not t:
        return True
    if _CHECKBOX_RE.match(t):
        return True
    # Lone mark often used inside checkbox widgets.
    if len(t) <= 2 and not _LETTER_RE.search(t):
        return True
    return False


def _needs_translation(text: str) -> bool:
    t = (text or "").strip()
    if not t or _is_checkbox_or_symbol(t):
        return False
    if not _LETTER_RE.search(t):
        return False
    # Keep short uppercase codes (FHA, VA, ARM, USD) — MT mangles them and
    # expanding replacements smashes neighboring checkboxes.
    letters = "".join(c for c in t if c.isalpha())
    if 1 <= len(letters) <= 4 and letters.isupper() and len(t) <= 6:
        return False
    return True


def _luminance(rgb) -> float:
    return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]


def _is_usable_translation(text: str) -> bool:
    if not text or not text.strip():
        return False
    # Reject private-use / replacement garbage some Marian outputs emit.
    bad = sum(1 for ch in text if (0xE000 <= ord(ch) <= 0xF8FF) or ch == "\ufffd")
    return bad * 2 < max(1, len(text.strip()))


def _decode_hypothesis(target_tokenizer, pieces) -> str:
    filtered = [
        p
        for p in pieces
        if p
        and not (p.startswith("<") and p.endswith(">"))
        and not (p.startswith(">>") and p.endswith("<<"))
    ]
    return target_tokenizer.decode(filtered).strip()


def _translate_texts(from_code: str, to_code: str, texts):
    translator, (source_tokenizer, target_tokenizer), prefix = _load_pair(
        from_code, to_code
    )
    batch_tokens = []
    batch_index = []
    results = [""] * len(texts)

    def flush():
        nonlocal batch_tokens, batch_index
        if not batch_tokens:
            return
        translated = translator.translate_batch(
            batch_tokens,
            beam_size=2,
            return_scores=False,
        )
        for idx, item in zip(batch_index, translated):
            source_text = texts[idx]
            best = ""
            for hyp in item.hypotheses or []:
                candidate = _decode_hypothesis(target_tokenizer, hyp)
                if _is_usable_translation(candidate):
                    best = candidate
                    break
            results[idx] = best if best else source_text
        batch_tokens = []
        batch_index = []

    for i, text in enumerate(texts):
        raw = "" if text is None else str(text)
        if not raw.strip():
            results[i] = raw
            continue
        tokens = source_tokenizer.encode(raw, out_type=str)
        if prefix:
            tokens = [prefix, *tokens]
        batch_tokens.append(tokens)
        batch_index.append(i)
        if len(batch_tokens) >= 64:
            flush()
    flush()
    return results


def _fontname_for(to_code: str) -> str:
    if to_code == "zh":
        return "china-s"
    if to_code == "ja":
        return "japan"
    if to_code == "ko":
        return "korea"
    return "helv"


def _color_tuple(color_int: int):
    # PyMuPDF span color is usually an int 0xRRGGBB
    r = ((color_int >> 16) & 255) / 255.0
    g = ((color_int >> 8) & 255) / 255.0
    b = (color_int & 255) / 255.0
    return (r, g, b)


def _sample_bg_color(page: fitz.Page, rect: fitz.Rect, pix: fitz.Pixmap):
    """Sample page pixels around a glyph box so redaction fill matches the real background."""
    scale = pix.width / page.rect.width if page.rect.width else 2.0

    def sample(x: float, y: float):
        ix = int(x * scale)
        iy = int(y * scale)
        ix = max(0, min(pix.width - 1, ix))
        iy = max(0, min(pix.height - 1, iy))
        return pix.pixel(ix, iy)

    r = fitz.Rect(rect)
    # Prefer points just outside the ink so we don't sample the glyph color.
    candidates = [
        (r.x0 - 1.2, (r.y0 + r.y1) * 0.5),
        (r.x1 + 1.2, (r.y0 + r.y1) * 0.5),
        ((r.x0 + r.x1) * 0.5, r.y0 - 1.2),
        ((r.x0 + r.x1) * 0.5, r.y1 + 1.2),
        (r.x0 - 1.0, r.y0 - 1.0),
        (r.x1 + 1.0, r.y0 - 1.0),
        (r.x0 - 1.0, r.y1 + 1.0),
        (r.x1 + 1.0, r.y1 + 1.0),
    ]
    samples = []
    for x, y in candidates:
        if page.rect.contains(fitz.Point(x, y)):
            samples.append(sample(x, y))
    if not samples:
        return (1.0, 1.0, 1.0)

    # Median RGB — robust against nearby rule lines / glyph edges.
    samples.sort()
    mid = samples[len(samples) // 2]
    return (mid[0] / 255.0, mid[1] / 255.0, mid[2] / 255.0)


def _contrast_text_color(fill_rgb, span_color_int: int):
    text = _color_tuple(span_color_int)
    fill_lum = _luminance(fill_rgb)
    text_lum = _luminance(text)
    # Black header bars often report dark span color incorrectly after sampling;
    # force readable contrast.
    if fill_lum < 0.40 and text_lum < 0.55:
        return (1.0, 1.0, 1.0)
    if fill_lum > 0.82 and text_lum > 0.82:
        return (0.0, 0.0, 0.0)
    return text


def _collect_spans(page: fitz.Page):
    spans = []
    data = page.get_text("dict", flags=fitz.TEXT_PRESERVE_WHITESPACE)
    for block in data.get("blocks", []):
        if block.get("type") != 0:
            continue
        for line in block.get("lines", []):
            for span in line.get("spans", []):
                text = span.get("text", "")
                if not text or not text.strip():
                    continue
                bbox = span.get("bbox")
                if not bbox:
                    continue
                spans.append(
                    {
                        "text": text,
                        "bbox": bbox,
                        "size": float(span.get("size") or 10),
                        "color": int(span.get("color") or 0),
                        "flags": int(span.get("flags") or 0),
                    }
                )
    return spans


def _right_neighbor_x(spans, idx: int) -> float | None:
    """Right edge limit from the next span on roughly the same baseline."""
    rect = fitz.Rect(spans[idx]["bbox"])
    y_mid = (rect.y0 + rect.y1) * 0.5
    best = None
    for j, other in enumerate(spans):
        if j == idx:
            continue
        o = fitz.Rect(other["bbox"])
        o_mid = (o.y0 + o.y1) * 0.5
        if abs(o_mid - y_mid) > max(2.0, rect.height * 0.55):
            continue
        if o.x0 <= rect.x0 + 0.5:
            continue
        if best is None or o.x0 < best:
            best = o.x0
    return best


def _fit_fontsize(text: str, fontname: str, max_width: float, start: float) -> float:
    size = max(4.0, start)
    while size >= 4.0:
        try:
            width = fitz.get_text_length(text, fontname=fontname, fontsize=size)
        except Exception:  # noqa: BLE001
            width = len(text) * size * 0.55
        if width <= max(1.0, max_width):
            return size
        size -= 0.4
    return 4.0


def _translate_page(pdf_path: str, page_index: int, from_code: str, to_code: str) -> bytes:
    doc = fitz.open(pdf_path)
    try:
        if page_index < 0 or page_index >= doc.page_count:
            raise RuntimeError(f"Page index out of range: {page_index}")

        page = doc[page_index]
        spans = _collect_spans(page)
        if not spans:
            single = fitz.open()
            single.insert_pdf(doc, from_page=page_index, to_page=page_index)
            return single.tobytes()

        translate_indices = []
        translate_inputs = []
        for i, span in enumerate(spans):
            if _needs_translation(span["text"]):
                translate_indices.append(i)
                translate_inputs.append(span["text"])

        translated_map = {}
        if translate_inputs:
            outputs = _translate_texts(from_code, to_code, translate_inputs)
            for idx, text in zip(translate_indices, outputs):
                cleaned = (text or "").strip()
                # Drop SentencePiece / junk tokens that smash layout.
                cleaned = cleaned.replace("▁", " ").replace("_", " ")
                cleaned = re.sub(r"\s+", " ", cleaned).strip()
                if cleaned and cleaned != spans[idx]["text"]:
                    translated_map[idx] = cleaned

        # Snapshot for background sampling before any redaction mutates the page.
        pix = page.get_pixmap(matrix=fitz.Matrix(2, 2), alpha=False)

        # Tight redaction with background-matched fill (no opaque white slabs).
        for idx in translated_map:
            rect = fitz.Rect(spans[idx]["bbox"])
            # Minimal pad — large pads paint over nearby checkboxes/vector marks.
            rect = fitz.Rect(rect.x0 - 0.15, rect.y0 - 0.1, rect.x1 + 0.15, rect.y1 + 0.1)
            fill = _sample_bg_color(page, fitz.Rect(spans[idx]["bbox"]), pix)
            page.add_redact_annot(rect, fill=fill)

        # Keep vector checkboxes / rules; only remove covered text glyphs.
        page.apply_redactions(
            images=fitz.PDF_REDACT_IMAGE_NONE,
            graphics=fitz.PDF_REDACT_LINE_ART_NONE,
        )

        fontname = _fontname_for(to_code)

        for idx, translated in translated_map.items():
            span = spans[idx]
            rect = fitz.Rect(span["bbox"])
            neighbor = _right_neighbor_x(spans, idx)
            if neighbor is not None:
                rect.x1 = min(rect.x1, neighbor - 0.6)
            # Never grow past original width — shrink font instead of colliding.
            rect.x1 = max(rect.x0 + 2.0, rect.x1)

            fill = _sample_bg_color(page, fitz.Rect(span["bbox"]), pix)
            color = _contrast_text_color(fill, span["color"])
            fontsize = _fit_fontsize(translated, fontname, rect.width, span["size"])

            # Baseline insert (no textbox background). Keep inside original box.
            baseline_y = rect.y0 + fontsize * 0.82
            if baseline_y > rect.y1:
                baseline_y = rect.y1 - 0.5
            page.insert_text(
                (rect.x0, baseline_y),
                translated,
                fontsize=fontsize,
                fontname=fontname,
                color=color,
            )

        single = fitz.open()
        single.insert_pdf(doc, from_page=page_index, to_page=page_index)
        return single.tobytes()
    finally:
        doc.close()


def handle(req: dict) -> dict:
    cmd = req.get("cmd")
    if cmd == "ping":
        return {"ok": True, "engine": "ct2+pymupdf", "models_dir": str(MODELS_DIR)}

    if cmd == "list_languages":
        return {"ok": True, "languages": _list_languages()}

    if cmd == "list_catalog":
        payload = _list_catalog()
        payload["ok"] = True
        return payload

    if cmd == "prepare":
        from_code = _normalize(req.get("from", "en"))
        to_code = _normalize(req.get("to", "zh"))
        info = _ensure_model(from_code, to_code)
        _load_pair(from_code, to_code)
        return {
            "ok": True,
            "from": from_code,
            "to": to_code,
            "status": "ready",
            "downloaded": info.get("downloaded", False),
            "path": info.get("path"),
        }

    if cmd == "translate":
        from_code = _normalize(req.get("from", "en"))
        to_code = _normalize(req.get("to", "zh"))
        texts = req.get("texts") or []
        if not isinstance(texts, list):
            raise RuntimeError("'texts' must be a list")
        translations = _translate_texts(from_code, to_code, texts)
        return {
            "ok": True,
            "from": from_code,
            "to": to_code,
            "translations": translations,
        }

    if cmd == "translate_page":
        from_code = _normalize(req.get("from", "en"))
        to_code = _normalize(req.get("to", "zh"))
        pdf_path = req.get("pdf_path")
        page_index = int(req.get("page", 0))
        if not pdf_path or not Path(pdf_path).exists():
            raise RuntimeError(f"PDF not found: {pdf_path}")
        page_bytes = _translate_page(pdf_path, page_index, from_code, to_code)
        return {
            "ok": True,
            "page": page_index,
            "page_pdf_b64": base64.b64encode(page_bytes).decode("ascii"),
            "engine": "ct2+pymupdf",
        }

    raise RuntimeError(f"Unknown cmd: {cmd}")


def main() -> int:
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    _reply(
        {
            "ok": True,
            "event": "ready",
            "engine": "ct2+pymupdf",
            "python": sys.version.split()[0],
            "root": str(ROOT),
            "models_dir": str(MODELS_DIR),
        }
    )
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            _reply(handle(req))
        except Exception as exc:  # noqa: BLE001
            _reply(
                {
                    "ok": False,
                    "error": str(exc),
                    "trace": traceback.format_exc(limit=8),
                }
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

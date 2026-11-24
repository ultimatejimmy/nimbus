#!/usr/bin/env python3
import os
import re
import sys
import json
import urllib.request
import urllib.error
import time
import hashlib
import argparse
import ast

# Reconfigure stdout/stderr for UTF-8
if sys.version_info >= (3, 7):
    try:
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    except Exception:
        pass

# Resolve directory paths
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if os.path.exists(os.path.join(SCRIPT_DIR, '..', 'koreader', 'nimbus.koplugin', '_meta.lua')):
    PLUGIN_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, '..', 'koreader', 'nimbus.koplugin'))
elif os.path.exists(os.path.join(SCRIPT_DIR, '..', 'nimbus.koplugin', '_meta.lua')):
    PLUGIN_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, '..', 'nimbus.koplugin'))
elif os.path.exists(os.path.join(SCRIPT_DIR, '..', '_meta.lua')):
    PLUGIN_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, '..'))
else:
    PLUGIN_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, '..', 'koreader', 'nimbus.koplugin'))

LANGUAGES_DIR = os.path.join(PLUGIN_DIR, 'languages')
SOURCE_DIR = PLUGIN_DIR
MASTER_LANG = 'en'

LANG_NAMES = {
    'ar': 'Arabic',
    'de': 'German',
    'en': 'English',
    'es': 'Spanish',
    'fr': 'French',
    'hu': 'Hungarian',
    'id': 'Indonesian',
    'it': 'Italian',
    'ja': 'Japanese',
    'ko': 'Korean',
    'nl': 'Dutch',
    'pl': 'Polish',
    'pt_br': 'Portuguese (Brazil)',
    'ru': 'Russian',
    'sk': 'Slovak',
    'sr': 'Serbian',
    'tr': 'Turkish',
    'uk': 'Ukrainian',
    'zh_CN': 'Simplified Chinese',
}

ALLOWLIST = {
    'path',
    'current_language',
    'plugin_name',
    'KOReader',
    'Beam',
    'Cloudflare',
    'Worker',
    'Nimbus',
    'Nimbus Cloud',
    'Dropbox',
    'Google Drive',
    'Microsoft OneDrive',
    'WebDAV',
    'CrossPoint / Sink / KOSync',
    'OK',
    'btn_ok',
    '1 / 1',
    'SHA-256',
    'TAR',
    'GZIP',
    'HTTP',
    'JSON',
    'QR',
    'Wi-Fi',
    '·',
    '•',
    '→',
    '—',
    '?',
}

DEFAULT_GEMINI_MODEL = "gemini-3.5-flash-lite"
DEFAULT_GEMINI_FALLBACK_MODELS = [
    "gemini-3.8-flash",
    "gemini-3.6-flash",
]

def get_md5(text):
    return hashlib.md5(text.encode('utf-8')).hexdigest()

def needs_translation(key, current_val, en_val, current_hash):
    if not key or key == 'language_name':
        return False
    if not current_val:
        return True
    if current_hash and en_val and current_hash != get_md5(en_val):
        return True
    if not current_hash and current_val == en_val and key not in ALLOWLIST:
        return True
    return False

def decode_po_string(s):
    if not s: return ""
    escapes = {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}
    return re.sub(r'\\([nt"\\])', lambda m: escapes[m.group(1)], s)

def encode_po_string(s):
    if not s: return ""
    return (s.replace("\\", "\\\\")
             .replace("\n", "\\n")
             .replace("\t", "\\t")
             .replace('"', '\\"'))

def format_specifiers(s):
    if not s: return []
    return re.findall(r'%(?:\d+\$)?[sd]', s)

def decode_lua_escapes(s):
    if '\\x' in s or '\\X' in s:
        try:
            s = re.sub(r'\\[xX]([0-9a-fA-F]{2})', lambda m: bytes([int(m.group(1), 16)]).decode('latin1'), s)
            s = s.encode('latin1').decode('utf-8')
        except Exception:
            pass
    return s

def extract_keys_from_lua(source_dir=None):
    src = source_dir or SOURCE_DIR
    used_keys = {}
    fallback_map = {}

    func_pattern = r'(?:_|_G\._|loc:t|loc:f|Localization:t|Localization:f)\s*\(\s*'
    dq_pattern = re.compile(func_pattern + r'"((?:[^"\\]|\\.)*)"')
    sq_pattern = re.compile(func_pattern + r"'((?:[^'\\]|\\.)*)'")
    bracket_pattern = re.compile(func_pattern + r'\[\[(.*?)\]\]', re.DOTALL)

    for root, _, files in os.walk(src):
        if 'languages' in root or 'tools' in root or 'tests' in root:
            continue
        for file in files:
            if file.endswith('.lua'):
                path = os.path.join(root, file)
                with open(path, 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read()
                    for m in dq_pattern.finditer(content):
                        k = m.group(1).replace('\\"', '"').replace('\\\\', '\\').replace('\\n', '\n')
                        k = decode_lua_escapes(k)
                        if k and k not in ('%s', '%d'):
                            used_keys[k] = used_keys.get(k, "")
                    for m in sq_pattern.finditer(content):
                        k = m.group(1).replace("\\'", "'").replace('\\\\', '\\').replace('\\n', '\n')
                        k = decode_lua_escapes(k)
                        if k and k not in ('%s', '%d'):
                            used_keys[k] = used_keys.get(k, "")
                    for m in bracket_pattern.finditer(content):
                        k = decode_lua_escapes(m.group(1))
                        if k and k not in ('%s', '%d'):
                            used_keys[k] = used_keys.get(k, "")

                    if file == 'localization_backup.lua':
                        m_fb = re.search(r'local FALLBACKS = \{(.*?)\n\}', content, re.DOTALL)
                        if m_fb:
                            for line in m_fb.group(1).splitlines():
                                m = re.search(r'^\s*(?:\["((?:[^"\\]|\\.)*)"\]|([a-zA-Z0-9_]+))\s*=\s*"((?:[^"\\]|\\.)*)"', line)
                                if m:
                                    k = m.group(1) if m.group(1) is not None else m.group(2)
                                    v = m.group(3)
                                    k = decode_lua_escapes(k.replace('\\"', '"').replace('\\\\', '\\'))
                                    v = decode_lua_escapes(v.replace('\\"', '"').replace('\\\\', '\\'))
                                    used_keys[k] = v
                                    fallback_map[k] = v
                        m_ka = re.search(r'local KEY_ALIASES = \{(.*?)\n\}', content, re.DOTALL)
                        if m_ka:
                            for line in m_ka.group(1).splitlines():
                                m = re.search(r'^\s*\["((?:[^"\\]|\\.)*)"\]\s*=\s*"((?:[^"\\]|\\.)*)"', line)
                                if m:
                                    alias = decode_lua_escapes(m.group(1).replace('\\"', '"').replace('\\\\', '\\'))
                                    target = decode_lua_escapes(m.group(2).replace('\\"', '"').replace('\\\\', '\\'))
                                    used_keys[alias] = used_keys.get(alias, "")
                                    used_keys[target] = used_keys.get(target, "")

    used_keys.pop("", None)
    return set(used_keys.keys()), fallback_map, used_keys

def parse_po(file_path):
    entries = []
    current_entry = {'msgid': '', 'msgstr': '', 'comments': [], 'en_hash': None}
    current_field = None
    if not os.path.exists(file_path): return []
    with open(file_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                if current_entry['msgid'] or current_entry['msgstr']:
                    entries.append(current_entry)
                    current_entry = {'msgid': '', 'msgstr': '', 'comments': [], 'en_hash': None}
                current_field = None
                continue
            if line.startswith('#'):
                current_entry['comments'].append(line)
                m = re.match(r'^#\s*en-hash:\s*([a-f0-9]+)$', line)
                if m:
                    current_entry['en_hash'] = m.group(1)
            elif line.startswith('msgid '):
                m = re.match(r'^msgid "(.*)"$', line)
                if m:
                    current_entry['msgid'] = decode_po_string(m.group(1))
                current_field = 'msgid'
            elif line.startswith('msgstr '):
                m = re.match(r'^msgstr "(.*)"$', line)
                if m:
                    current_entry['msgstr'] = decode_po_string(m.group(1))
                current_field = 'msgstr'
            elif line.startswith('"'):
                m = re.match(r'^"(.*)"$', line)
                if m:
                    val = decode_po_string(m.group(1))
                    if current_field == 'msgid':
                        current_entry['msgid'] += val
                    elif current_field == 'msgstr':
                        current_entry['msgstr'] += val
        if current_entry['msgid'] or current_entry['msgstr']:
            entries.append(current_entry)
    return entries

def save_po(file_path, lang_name, lang_code, keys, translations, fallback_map, en_final, existing_hashes=None):
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    existing_hashes = existing_hashes or {}
    chunks = [
        'msgid ""\nmsgstr ""\n',
        f'"Language-Team: {lang_name}\\n"\n',
        f'"Language: {lang_code}\\n"\n',
        '"Content-Type: text/plain; charset=UTF-8\\n"\n',
        '"Content-Transfer-Encoding: 8bit\\n"\n\n',
    ]
    for key in sorted(keys):
        if not key:
            continue
        if lang_code == 'en':
            val = translations.get(key)
            if (not val or val == key) and key in fallback_map:
                val = fallback_map[key]
            elif not val:
                val = key
        else:
            val = translations.get(key, "")

        if lang_code != 'en':
            en_val = en_final.get(key, "")
            prev_hash = existing_hashes.get(key)
            # Only stamp the new en-hash if the key is actually translated and up-to-date.
            # If it is still missing or failed to translate, preserve prev_hash so it stays flagged.
            if needs_translation(key, val, en_val, prev_hash):
                if prev_hash:
                    chunks.append(f'# en-hash: {prev_hash}\n')
            elif en_val:
                chunks.append(f'# en-hash: {get_md5(en_val)}\n')
        chunks.append(f'msgid "{encode_po_string(key)}"\n')
        chunks.append(f'msgstr "{encode_po_string(val)}"\n\n')

    with open(file_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(''.join(chunks))

def validate_translations(lang_code, requested, translated):
    if not isinstance(translated, dict):
        return [f"{lang_code}: provider did not return a translations object"]

    errors = []
    for key, english in requested.items():
        value = translated.get(key)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{lang_code}: missing translation for {key!r}")
        elif "???" in value:
            errors.append(f"{lang_code}: placeholder/corrupt translation for {key!r}")
        elif value == english and key not in ALLOWLIST:
            errors.append(f"{lang_code}: English fallback returned for {key!r}")
        elif format_specifiers(value) != format_specifiers(english):
            errors.append(f"{lang_code}: format specifiers differ for {key!r}")
    return errors

def get_gemini_key():
    return os.environ.get("GEMINI_API_KEY")

def parse_json_response(text):
    if not text:
        return None
    text_stripped = text.strip()
    first_brace = text_stripped.find('{')
    last_brace = text_stripped.rfind('}')
    if first_brace != -1 and last_brace != -1:
        json_str = text_stripped[first_brace:last_brace+1]
    else:
        json_str = text_stripped

    # 1. Direct json.loads
    try:
        return json.loads(json_str, strict=False)
    except Exception:
        pass

    # 2. ast.literal_eval for Python-style dicts / single quotes
    try:
        val = ast.literal_eval(json_str)
        if isinstance(val, dict):
            return val
    except Exception:
        pass

    # 3. Fix unescaped backslashes
    cleaned = re.sub(r'\\(?!([\"\\/bfnrt]|u[0-9a-fA-F]{4}))', r'\\\\', json_str)
    try:
        return json.loads(cleaned, strict=False)
    except Exception:
        pass

    # 4. Fix unescaped newlines
    cleaned2 = re.sub(r'(?<!\\)\n', r'\\n', cleaned)
    try:
        return json.loads(cleaned2, strict=False)
    except Exception:
        pass

    # 5. Remove JavaScript-style comments and trailing commas
    cleaned3 = re.sub(r'//[^\n]*', '', json_str)
    cleaned3 = re.sub(r'/\*.*?\*/', '', cleaned3, flags=re.DOTALL)
    cleaned3 = re.sub(r',\s*([\]}])', r'\1', cleaned3)
    try:
        return json.loads(cleaned3, strict=False)
    except Exception:
        pass

    # 6. Replace single quotes around keys/values with double quotes
    try:
        converted = re.sub(r"(?<!\\)'", '"', json_str)
        return json.loads(converted, strict=False)
    except Exception:
        pass

    return None

def get_gemini_models(primary_model=None, fallback_models=None):
    primary = (primary_model or os.environ.get("GEMINI_MODEL") or DEFAULT_GEMINI_MODEL).strip()
    if fallback_models is None:
        env_fallbacks = os.environ.get("GEMINI_FALLBACK_MODELS", "")
        if env_fallbacks.strip():
            fallback_list = [m.strip() for m in env_fallbacks.split(",") if m.strip()]
        else:
            fallback_list = list(DEFAULT_GEMINI_FALLBACK_MODELS)
    else:
        fallback_list = [m.strip() for m in fallback_models if m and m.strip()]

    models = []
    for m in [primary] + fallback_list:
        if m and m not in models:
            models.append(m)
    return models

def call_gemini(prompt, models=None):
    key = get_gemini_key()
    if not key:
        return None

    model_list = models if models else get_gemini_models()
    headers = {"Content-Type": "application/json"}
    data = json.dumps({
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {"responseMimeType": "application/json"}
    }).encode('utf-8')

    max_retries_per_model = 2
    for model_idx, model in enumerate(model_list):
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={key}"
        if model_idx > 0:
            print(f"  - Falling back to model: {model}...")

        for attempt in range(max_retries_per_model):
            req = urllib.request.Request(url, data=data, headers=headers, method='POST')
            try:
                with urllib.request.urlopen(req, timeout=90) as response:
                    res_data = json.loads(response.read().decode('utf-8'))
                    parts = res_data.get('candidates', [{}])[0].get('content', {}).get('parts', [])
                    if not parts:
                        if attempt < max_retries_per_model - 1:
                            time.sleep(3 * (attempt + 1))
                            continue
                        print(f"API Error ({model}): Empty response candidates.")
                        break
                    text = parts[0].get('text', '')
                    parsed = parse_json_response(text)
                    if parsed:
                        return parsed

                    if attempt < max_retries_per_model - 1:
                        print(f"  - Invalid JSON from {model} (attempt {attempt + 1}/{max_retries_per_model}). Retrying...")
                        time.sleep(3 * (attempt + 1))
                        continue
                    print(f"API Error ({model}): Failed to parse JSON response.")
                    break
            except urllib.error.HTTPError as e:
                if e.code in (429, 500, 502, 503, 504) and attempt < max_retries_per_model - 1:
                    sleep_time = 10 * (attempt + 1)
                    print(f"  - {model}: HTTP {e.code}, waiting {sleep_time}s before retry {attempt + 1}/{max_retries_per_model - 1}...")
                    time.sleep(sleep_time)
                else:
                    print(f"API Error calling Gemini ({model}): {e}")
                    break
            except urllib.error.URLError as e:
                print(f"API Connection Error ({model}): {e}")
                if attempt < max_retries_per_model - 1:
                    time.sleep(5)
                else:
                    break
            except Exception as e:
                if attempt < max_retries_per_model - 1:
                    print(f"  - Request/parse warning ({model}): {e}. Retrying ({attempt + 1}/{max_retries_per_model - 1})...")
                    time.sleep(3 * (attempt + 1))
                    continue
                print(f"API Error ({model}): {e}")
                break
    return None

def _is_valid_translation(key, english, value):
    if not isinstance(value, str) or not value.strip():
        return False, "empty"
    if "???" in value:
        return False, "placeholder"
    if format_specifiers(value) != format_specifiers(english):
        return False, "format specifiers differ"
    return True, None

def translate_all_gemini(all_untranslated, lang_names, max_pairs=40, models=None, on_batch_complete=None):
    flat_pairs = []
    for lang_code, keys in all_untranslated.items():
        for key, en_val in keys.items():
            flat_pairs.append((lang_code, key, en_val))

    if not flat_pairs:
        return {}

    all_results = {}
    total_batches = (len(flat_pairs) + max_pairs - 1) // max_pairs

    for i in range(0, len(flat_pairs), max_pairs):
        chunk = flat_pairs[i:i+max_pairs]
        batch_num = i // max_pairs + 1

        batch_dict = {}
        requested_by_lang = {}
        for lang_code, key, en_val in chunk:
            if lang_code not in batch_dict:
                batch_dict[lang_code] = []
                requested_by_lang[lang_code] = {}
            batch_dict[lang_code].append({"key": key, "english": en_val})
            requested_by_lang[lang_code][key] = en_val

        lang_lookup = {lc.lower(): lc for lc in batch_dict}

        targets = []
        for lang_code, strings in batch_dict.items():
            name = lang_names.get(lang_code, lang_code.capitalize())
            targets.append({
                "language_code": lang_code,
                "language_name": name,
                "strings": strings
            })

        prompt = f"""You are a professional translator and localization expert. Translate the following English key-value pairs for a KOReader Device Backup & Restore plugin UI into their respective target languages.

For each target language, you will receive its language name, language code, and a list of key-value pairs where the values are in English. Translate the English values into the target language, keeping them short, clear, and natural for e-reader menus and dialogs.

CRITICAL rules:
1. "KOReader", "Beam", "Cloudflare" are brand names and must NEVER be translated. Keep them unchanged.
2. Retain all format specifiers such as %s, %d, %1$s, %2$d, etc. exactly in the translated output.
3. Retain all literal escaped newlines (\\n) and tabs (\\t) exactly.
4. Keep translations concise, natural, and suited for a mobile e-reader display.
5. All keys and values must be enclosed in standard double quotes ("). Never use single quotes ('). Do not include trailing commas or comments.
6. Return ONLY a valid JSON object matching this exact schema:
{{
  "translations": {{
    "<language_code>": {{
      "key_name": "translated_value"
    }}
  }}
}}
Do not add markdown blocks, explanations, or backticks.

Target languages and strings to translate:
{json.dumps(targets, indent=2, ensure_ascii=False)}
"""
        print(f"  - Requesting translations for batch {batch_num}/{total_batches} ({len(chunk)} strings)...")
        result = call_gemini(prompt, models=models)

        if result and isinstance(result, dict) and isinstance(result.get("translations"), dict):
            translations = result["translations"]
            batch_results = {}
            rejected_count = 0
            for raw_lang_code, tr_map in translations.items():
                lang_code = raw_lang_code if raw_lang_code in requested_by_lang else lang_lookup.get(str(raw_lang_code).lower())
                if not lang_code or not isinstance(tr_map, dict):
                    continue
                req_map = requested_by_lang[lang_code]
                for k, v in tr_map.items():
                    if k not in req_map:
                        continue
                    val_str = str(v) if v is not None else ""
                    ok, reason = _is_valid_translation(k, req_map[k], val_str)
                    if not ok:
                        rejected_count += 1
                        print(f"  - WARNING: Rejected {lang_code} translation for {k!r} ({reason}).")
                        continue
                    batch_results.setdefault(lang_code, {})[k] = val_str
                    all_results.setdefault(lang_code, {})[k] = val_str

            missing_in_batch = sum(
                1 for lc, req_map in requested_by_lang.items()
                for k in req_map
                if k not in batch_results.get(lc, {})
            )
            if missing_in_batch:
                print(f"  - WARNING: Batch {batch_num} left {missing_in_batch} string(s) untranslated/invalid (kept valid results).")
            if batch_results and on_batch_complete:
                on_batch_complete(batch_results)
        else:
            print(f"  - WARNING: Batch {batch_num} failed or returned invalid response.")

        if i + max_pairs < len(flat_pairs):
            time.sleep(1.5)

    return all_results

def sync():
    parser = argparse.ArgumentParser(description="Synchronize and translate KOReader Device Backup & Restore plugin localizations.")
    parser.add_argument("-m", "--mode", choices=["auto", "manual", "skip"], help="Translation mode: auto (Gemini), manual (interactive CLI), or skip.")
    parser.add_argument("--model", help=f"Primary Gemini model (default: $GEMINI_MODEL or {DEFAULT_GEMINI_MODEL}).")
    parser.add_argument("--fallback-models", help="Comma-separated fallback Gemini models (default: $GEMINI_FALLBACK_MODELS or built-in list).")
    args = parser.parse_args()

    print("--- Starting Translation Sync ---")

    all_keys, fallback_map, used_keys = extract_keys_from_lua()
    print(f"Found {len(used_keys)} keys in source code.")

    os.makedirs(LANGUAGES_DIR, exist_ok=True)
    en_path = os.path.join(LANGUAGES_DIR, f'{MASTER_LANG}.po')
    en_entries = parse_po(en_path)
    en_existing = {e['msgid']: e['msgstr'] for e in en_entries if e['msgid']}

    en_final = {}
    for key in sorted(used_keys):
        code_fb = fallback_map.get(key)
        en_final[key] = (en_existing.get(key) or code_fb or key)

    save_po(en_path, 'English', 'en', en_final.keys(), en_final, fallback_map, en_final)
    print(f"Updated {MASTER_LANG}.po with {len(en_final)} keys.")

    # Ensure all target language PO files exist
    for lang_code, lang_name in sorted(LANG_NAMES.items()):
        if lang_code == MASTER_LANG: continue
        target_path = os.path.join(LANGUAGES_DIR, f"{lang_code}.po")
        if not os.path.exists(target_path):
            save_po(target_path, lang_name, lang_code, en_final.keys(), {}, fallback_map, en_final)

    lang_files = [f for f in sorted(os.listdir(LANGUAGES_DIR)) if f.endswith('.po') and not f.startswith(MASTER_LANG)]

    all_existing_tr = {}
    all_existing_hashes = {}
    all_untranslated = {}
    lang_names = {}

    for file in lang_files:
        lang_code = file.split('.')[0]
        path = os.path.join(LANGUAGES_DIR, file)
        entries = parse_po(path)

        lang_name = LANG_NAMES.get(lang_code, lang_code.capitalize())
        for e in entries:
            if e['msgid'] == '':
                m = re.search(r'Language-Team: (.*?)\\n', e['msgstr'])
                if m: lang_name = m.group(1)
        lang_names[lang_code] = lang_name

        existing_tr = {e['msgid']: e['msgstr'] for e in entries if e['msgid'] and e['msgstr']}
        existing_hashes = {e['msgid']: e['en_hash'] for e in entries if e['msgid']}

        all_existing_tr[lang_code] = existing_tr
        all_existing_hashes[lang_code] = existing_hashes

        untranslated = {}
        for key in en_final:
            current_val = existing_tr.get(key, "")
            en_val = en_final.get(key, "")
            current_hash = existing_hashes.get(key)
            if needs_translation(key, current_val, en_val, current_hash):
                untranslated[key] = en_val

        if untranslated:
            all_untranslated[lang_code] = untranslated

    def save_lang_po(lang_code):
        path = os.path.join(LANGUAGES_DIR, f"{lang_code}.po")
        save_po(
            path,
            lang_names[lang_code],
            lang_code,
            en_final.keys(),
            all_existing_tr[lang_code],
            fallback_map,
            en_final,
            existing_hashes=all_existing_hashes[lang_code],
        )

    def handle_batch_complete(batch_results):
        for lang_code, tr_map in batch_results.items():
            if lang_code not in all_existing_tr:
                continue
            for k, v in tr_map.items():
                all_existing_tr[lang_code][k] = v
                en_val = en_final.get(k, "")
                if en_val:
                    all_existing_hashes[lang_code][k] = get_md5(en_val)
            save_lang_po(lang_code)

    mode = args.mode
    has_gemini = get_gemini_key() is not None

    if all_untranslated:
        print("\nMissing, outdated, or empty translations detected:")
        for lang_code, keys in sorted(all_untranslated.items()):
            name = lang_names.get(lang_code, lang_code.capitalize())
            print(f"  - {name} ({lang_code}): {len(keys)} key(s)")

        if not mode:
            mode = "auto" if has_gemini else "skip"

        if mode == "auto":
            if not has_gemini:
                print("\nError: GEMINI_API_KEY is not set.")
                mode = "skip"
            else:
                fb_list = [m.strip() for m in args.fallback_models.split(",") if m.strip()] if args.fallback_models else None
                models = get_gemini_models(primary_model=args.model, fallback_models=fb_list)
                print(f"\nAuto-translating using Gemini API (models: {' -> '.join(models)})...")
                translate_all_gemini(
                    all_untranslated,
                    lang_names,
                    models=models,
                    on_batch_complete=handle_batch_complete,
                )

    total_remaining = 0
    for file in lang_files:
        lang_code = file.split('.')[0]
        save_lang_po(lang_code)
        existing_tr = all_existing_tr[lang_code]
        existing_hashes = all_existing_hashes[lang_code]
        missing_count = sum(
            1 for k in en_final
            if needs_translation(k, existing_tr.get(k, ""), en_final.get(k, ""), existing_hashes.get(k))
        )
        total_remaining += missing_count
        print(f"Updated {file} ({missing_count} keys need translation)")

    print("--- Sync Complete ---")
    if mode == "auto" and total_remaining > 0:
        print(f"Warning: {total_remaining} translation(s) still remaining after auto-translation.")
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(sync())

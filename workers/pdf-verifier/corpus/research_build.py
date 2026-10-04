#!/usr/bin/env python3
"""Offline wrapper-only diagnostics. Never changes/adopts the frozen verifier.

Reuse the existing hash-pinned qpdf library and SDK. A copied frozen compiler
cache and separate outputs prevent writes to the original build. No dependency
download path exists. Numeric probes preserve limits and terminal result codes.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT/'workers/pdf-verifier/corpus'
BASE = ROOT/'.artifacts/pdf-verifier'
OUT = BASE/'corpus/research'
IDENTITY = '2fea7b1c8f842c4c9402720a2f5c4ad8e9b7c343bcea5c6ee29210f1606028b0'
WARNING_PATTERNS = [
    'object has offset 0 - a common error', 'expected endobj', 'expected n n obj',
    'dictionary has duplicated key', 'unknown token while reading object',
    'dictionary keys but found non-name', 'expected endstream',
    'shared object', 'page length mismatch', 'object count mismatch for page',
    'space before first xref item (/T) mismatch', 'end of first page section (/E) mismatch',
    'hint table length mismatch', 'page 0 has shared identifier entries',
    'first page object offset mismatch', 'outline', 'extraneous whitespace',
    'expected ',
]


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def canonical(value): return json.dumps(value,sort_keys=True,separators=(',',':')).encode()


PROBES = r'''
// Research-only numeric observations; no parser/document strings leave WASM.
// 0 stage, 1 terminal line, 2 limit kind, 3 stream bytes attempted,
// 4 content bytes attempted, 5 content objects attempted, 6 object count,
// 7 current object ID, 8 exception code, 9 warning count, 10 warning-code mask,
// 11 current filter mask, 12 global limit errors, 13 exception byte offset,
// 14..31 known warning-category counts, 45 other warning count,
// 46 warnings immediately after getObjectCount/fixDanglingReferences.
uint32_t research[47] = {};
int recorded(int result, int line) { research[1] = line; return result; }
void capture_warnings(QPDF& document)
{
    auto observed = document.getWarnings();
    research[9] += observed.size();
    for (auto const& warning : observed) {
        unsigned code = static_cast<unsigned>(warning.getErrorCode());
        research[10] |= code < 31 ? 1u << code : 1u << 31;
        const char* patterns[] = {@@PATTERNS@@};
        auto const& message = warning.getMessageDetail();
        bool classified = false;
        for (unsigned i = 0; i < sizeof(patterns)/sizeof(patterns[0]); ++i) {
            if (message.find(patterns[i]) != std::string::npos) {
                ++research[14 + i]; classified = true; break;
            }
        }
        if (!classified) ++research[45];
    }
}
uint32_t filter_mask(QPDFObjectHandle filter)
{
    if (filter.isNull()) return 0;
    if (filter.isArray()) {
        uint32_t result = 0;
        int count = filter.getArrayNItems();
        for (int i = 0; i < count && i < 8; ++i) result |= filter_mask(filter.getArrayItem(i));
        return result | (count > 8 ? 1u << 30 : 0);
    }
    const char* names[] = {"/FlateDecode", "/DCTDecode", "/JPXDecode", "/JBIG2Decode",
        "/LZWDecode", "/ASCII85Decode", "/ASCIIHexDecode", "/RunLengthDecode", "/Crypt"};
    for (unsigned i = 0; i < 9; ++i) if (filter.isNameAndEquals(names[i])) return 1u << i;
    return 1u << 31;
}
'''


def instrument(original):
    text = original
    def replace(before, after, expected=1):
        nonlocal text
        if text.count(before) != expected: raise RuntimeError('frozen_wrapper_instrumentation_mismatch')
        text = text.replace(before, after)
    replace('namespace {\n', 'namespace {\n'+PROBES.replace('@@PATTERNS@@', ', '.join(json.dumps(p) for p in WARNING_PATTERNS)))
    replace('return after == before ? 0 : resource_limit;',
            'research[12] = after - before;\n    if (after != before) research[2] = 5;\n    return after == before ? 0 : resource_limit;')
    replace('if (length > remaining) throw LimitExceeded{};',
            'research[3] += length;\n        if (length > remaining) { research[2] = 1; throw LimitExceeded{}; }')
    replace('if (length > remaining_bytes) throw LimitExceeded{};',
            'research[4] += length;\n        if (length > remaining_bytes) { research[2] = 2; throw LimitExceeded{}; }')
    replace('if (!remaining_tokens) throw LimitExceeded{};',
            '++research[5];\n        if (!remaining_tokens) { research[2] = 3; throw LimitExceeded{}; }')
    replace('int pdfv_abi() { return 1; }',
            'uint32_t pdfv_research_metric(uint32_t index) { return index < 47 ? research[index] : 0; }\nint pdfv_abi() { return 1; }')
    replace('if (!bytes || length < 8)', 'std::memset(research, 0, sizeof(research));\n    research[0] = 1;\n    if (!bytes || length < 8)')
    replace('document.processMemoryFile(', 'research[0] = 2;\n        document.processMemoryFile(')
    replace('auto pages = QPDFPageDocumentHelper(document).getAllPages();',
            'research[0] = 3;\n        auto pages = QPDFPageDocumentHelper(document).getAllPages();')
    replace('if (document.isLinearized() && !document.checkLinearization()) return warnings;',
            'research[0] = 4;\n        if (document.isLinearized() && !document.checkLinearization()) { capture_warnings(document); return warnings; }')
    replace('if (document.getObjectCount() > object_limit) return resource_limit;',
            'research[0] = 5;\n        research[6] = document.getObjectCount();\n        research[46] = document.numWarnings();\n        if (research[6] > object_limit) { research[2] = 4; return resource_limit; }')
    replace('if (objects.size() > object_limit) return resource_limit;',
            'if (objects.size() > object_limit) { research[2] = 4; return resource_limit; }')
    replace('for (auto& object : objects) {',
            'research[0] = 6;\n        for (auto& object : objects) {\n            research[7] = object.getObjectID();')
    replace('auto filter = object.getDict().getKey("/Filter");',
            'auto filter = object.getDict().getKey("/Filter");\n                research[11] = filter_mask(filter);')
    replace('if (!okay) return malformed;', 'if (!okay) { capture_warnings(document); return malformed; }')
    replace('BoundedContents contents;', 'research[0] = 7;\n        BoundedContents contents;')
    replace('page.parseContents(&contents);', 'research[7] = page.getObjectHandle().getObjectID();\n            page.parseContents(&contents);')
    replace('if (document.anyWarnings()) return warnings;',
            'if (document.anyWarnings()) { capture_warnings(document); return warnings; }', 4)
    replace('} catch (QPDFExc const& error) {',
            '} catch (QPDFExc const& error) {\n        research[8] = error.getErrorCode();\n        research[13] = error.getFilePosition();')
    replace('} catch (std::bad_alloc const&) {', '} catch (std::bad_alloc const&) {\n        research[2] = 6;')
    text = re.sub(r'\breturn (malformed|encrypted|unsupported|resource_limit|warnings|internal_error|input_limit_exceeded|page_limit_exceeded);',
                  r'return recorded(\1, __LINE__);', text)
    return text


def main():
    if sha(BASE/'dist/identity.json') != IDENTITY: raise RuntimeError('frozen_identity_changed')
    identity = json.loads((BASE/'dist/identity.json').read_text())
    original = ROOT/'workers/pdf-verifier/verifier.cpp'
    library = BASE/'qpdf-build/libqpdf/libqpdf.a'
    for path, expected in ((original,identity['wrapper_sha256']), (library,identity['qpdf_library_sha256']),
        (BASE/'dist/verifier.wasm',identity['wasm_sha256']), (BASE/'dist/verifier.mjs',identity['javascript_sha256'])):
        if sha(path) != expected: raise RuntimeError('frozen_dependency_changed')
    OUT.mkdir(parents=True,exist_ok=True)
    wrapper = OUT/'verifier-research.cpp'
    wrapper.write_text(instrument(original.read_text()))
    cache = OUT/'cache'
    if not cache.exists(): shutil.copytree(BASE/'cache',cache,symlinks=False)
    config = OUT/'emscripten.config.py'
    config.write_text((BASE/'emscripten.config.py').read_text()+'FROZEN_CACHE = True\n')
    (OUT/'tmp').mkdir(exist_ok=True)
    environment = dict(os.environ, EM_CONFIG=str(config), EM_CACHE=str(cache), EMCC_CORES='4',
        TMPDIR=str(OUT/'tmp'), PYTHONDONTWRITEBYTECODE='1',
        EMSDK_PYTHON=str(BASE/'tools/python-3.13.3/python-3.13.3-0/bin/python3'))
    for key in ('CFLAGS','CXXFLAGS','LDFLAGS','EMCC_CFLAGS','EMCC_FORCE_STDLIBS'): environment.pop(key,None)
    build = json.loads((BASE/'dist/build.json').read_text())
    link = [str(BASE/'toolchain/install/emscripten/em++')] + build['link_arguments']
    if link[1] != str(original) or link[-1] != str(BASE/'dist/verifier.mjs'): raise RuntimeError('unexpected_original_link')
    link[1], link[-1] = str(wrapper), str(OUT/'verifier-research.mjs')
    for index, arg in enumerate(link):
        if arg.startswith('-sEXPORTED_FUNCTIONS='): link[index] += ',_pdfv_research_metric'
    with (OUT/'build.log').open('w') as log:
        subprocess.run(link,env=environment,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=120)
    research = {'research_only':True,'hosted_admitted':False,'original_build_identity_sha256':IDENTITY,
        'original_wrapper_sha256':identity['wrapper_sha256'],'qpdf_library_sha256':sha(library),
        'profile_sha256':identity['profile_sha256'],'limits_changed':False,
        'instrumentation_recipe_sha256':sha(Path(__file__)), 'wrapper_sha256':sha(wrapper),
        'wasm_sha256':sha(OUT/'verifier-research.wasm'),'javascript_sha256':sha(OUT/'verifier-research.mjs'),
        'warning_category_patterns':WARNING_PATTERNS,
        'scope':'numeric probes in wrapper only; same static library and limits; no admission authority'}
    (OUT/'identity.json').write_bytes(canonical(research))
    (OUT/'provenance.json').write_text(json.dumps({'link':link,'identity':research},indent=2)+'\n')
    if sha(BASE/'dist/identity.json') != IDENTITY: raise RuntimeError('frozen_identity_changed_after_research')
    print(json.dumps({'research_identity_sha256':sha(OUT/'identity.json'),**research},sort_keys=True))


if __name__ == '__main__': main()

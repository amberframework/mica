// Runs the web-platform-tests encoding/ test files (pinned in
// conformance/encoding/MANIFEST) under Node with TextDecoder, TextEncoder
// and a data:-URL XMLHttpRequest replaced by shims that do every
// conversion through Mica (conformance/encoding/oracle.cr). Node's own
// TextDecoder is never called.
//
//   node conformance/encoding/wpt_runner.js path/to/encoding_oracle [report.tsv]
//
// Prints one line per test file and a total, writes one row per subtest
// to the report, and exits non-zero when any subtest fails.
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', 'encoding-vectors', 'wpt');
const [oraclePath, reportPath] = process.argv.slice(2);
if (!oraclePath) {
  console.error('usage: node wpt_runner.js path/to/encoding_oracle [report.tsv]');
  process.exit(2);
}

// The test files run here: every .any.js file except the ones about
// encodeInto (a TextEncoder buffer API with nothing to convert), the IDL
// harness, and streams.
const FILES = [
  'api-basics.any.js', 'api-invalid-label.any.js', 'api-replacement-encodings.any.js',
  'api-surrogates-utf8.any.js', 'iso-2022-jp-decoder.any.js', 'replacement-encodings.any.js',
  'single-byte-decoder.any.js?TextDecoder', 'single-byte-decoder.any.js?XMLHttpRequest',
  'textdecoder-arguments.any.js', 'textdecoder-byte-order-marks.any.js', 'textdecoder-copy.any.js',
  'textdecoder-eof.any.js', 'textdecoder-fatal-single-byte.any.js', 'textdecoder-fatal-streaming.any.js',
  'textdecoder-fatal.any.js', 'textdecoder-ignorebom.any.js', 'textdecoder-labels.any.js',
  'textdecoder-mistakes.any.js', 'textdecoder-streaming.any.js', 'textdecoder-utf16-surrogates.any.js',
  'textencoder-constructor-non-utf.any.js', 'textencoder-utf16-surrogates.any.js',
  'unsupported-encodings.any.js', 'legacy-mb-schinese/gb18030/gb18030-decoder.any.js',
  'legacy-mb-schinese/gbk/gbk-decoder.any.js',
];

// --- The oracle -------------------------------------------------------------
const { OracleClient } = require('./oracle_client');
const client = new OracleClient(oraclePath);
const ask = request => client.ask(request);

function fromCodePoints(codePoints) {
  let text = '';
  for (let start = 0; start < codePoints.length; start += 4096) {
    text += String.fromCodePoint(...codePoints.slice(start, start + 4096));
  }
  return text;
}

// WebIDL USVString: lone surrogates become U+FFFD.
function toScalarValues(text) {
  const codePoints = [];
  for (let index = 0; index < text.length; index++) {
    const unit = text.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff && index + 1 < text.length) {
      const next = text.charCodeAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        codePoints.push(0x10000 + ((unit - 0xd800) << 10) + (next - 0xdc00));
        index++;
        continue;
      }
    }
    codePoints.push(unit >= 0xd800 && unit <= 0xdfff ? 0xfffd : unit);
  }
  return codePoints;
}

function bufferSourceBytes(input) {
  if (input === undefined) return [];
  if (input instanceof ArrayBuffer || (typeof SharedArrayBuffer !== 'undefined' && input instanceof SharedArrayBuffer)) {
    if (input.detached) return [];
    return Array.from(new Uint8Array(input));
  }
  if (ArrayBuffer.isView(input)) {
    if (input.buffer.detached) return [];
    return Array.from(new Uint8Array(input.buffer, input.byteOffset, input.byteLength));
  }
  throw new TypeError('not a BufferSource');
}

function dictionary(value) {
  if (value === undefined || value === null) return {};
  if (typeof value !== 'object' && typeof value !== 'function') throw new TypeError('not a dictionary');
  return value;
}

// --- Shims ------------------------------------------------------------------
class MicaTextDecoder {
  constructor(label = 'utf-8', options = undefined) {
    options = dictionary(options);
    const name = ask({ op: 'label', label: String(label) }).name;
    if (name === null || name === 'replacement') throw new RangeError(`The encoding label "${label}" is not supported`);
    this._encoding = name.toLowerCase();
    this._label = String(label);
    this._fatal = Boolean(options.fatal);
    this._ignoreBOM = Boolean(options.ignoreBOM);
    this._chunks = [];
    this._doNotFlush = false;
  }
  get encoding() { return this._encoding; }
  get fatal() { return this._fatal; }
  get ignoreBOM() { return this._ignoreBOM; }
  decode(input = undefined, options = undefined) {
    // WebIDL converts the arguments in order and the BufferSource keeps a
    // reference, so the bytes are read after the options (a getter may
    // detach the buffer).
    bufferSourceBytes(input === undefined ? undefined : input);
    options = dictionary(options);
    const stream = Boolean(options.stream);
    const bytes = bufferSourceBytes(input);
    if (!this._doNotFlush) this._chunks = [];
    this._doNotFlush = stream;
    this._chunks.push({ bytes, last: !this._doNotFlush });
    const response = ask({
      op: 'decode', label: this._label, fatal: this._fatal, ignore_bom: this._ignoreBOM, chunks: this._chunks,
    });
    const result = response.results[response.results.length - 1];
    if (result.error) {
      this._doNotFlush = false;
      this._chunks = [];
      throw new TypeError('The encoded data was not valid');
    }
    return fromCodePoints(result.code_points);
  }
}

class MicaTextEncoder {
  get encoding() { return 'utf-8'; }
  encode(input = '') {
    const response = ask({ op: 'encode', label: 'utf-8', code_points: toScalarValues(String(input)) });
    return Uint8Array.from(response.bytes);
  }
}

// XMLHttpRequest for data: URLs, decoding through the Encoding Standard's
// "decode" (byte order mark first, then the override charset, else UTF-8).
class MicaXMLHttpRequest {
  open(method, url) {
    this._url = url;
    // resources/single-byte-raw.py: bytes 0x00 to 0xFE labeled with ?label=.
    const raw = /^resources\/single-byte-raw\.py\?label=(.*)$/.exec(url);
    if (raw) this._charset = decodeURIComponent(raw[1]);
  }
  overrideMimeType(type) {
    const match = /charset="?([^";]*)"?/i.exec(type);
    this._charset = match ? match[1] : 'utf-8';
  }
  send() {
    const comma = this._url.indexOf(',');
    const bytes = this._url.startsWith('resources/single-byte-raw.py') ? Array.from({ length: 255 }, (_, byte) => byte) : Array.from(Buffer.from(this._url.slice(comma + 1).replace(/%([0-9a-fA-F]{2})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16))), 'latin1'));
    const response = ask({ op: 'decode_with_bom_sniff', label: this._charset, bytes });
    this.responseText = fromCodePoints(response.code_points);
    setImmediate(() => this.onload && this.onload());
  }
}

// --- testharness.js subset ---------------------------------------------------
class AssertionError extends Error {}
const results = [];
let pendingPromises = [];
let currentFile = '';

function sameValue(a, b) {
  return Object.is(a, b);
}
function formatValue(value) {
  if (typeof value === 'string') return JSON.stringify(value);
  return String(value);
}
function assert(condition, message) {
  if (!condition) throw new AssertionError(message);
}
const harness = {
  assert_equals(actual, expected, description = '') {
    assert(sameValue(actual, expected), `${description}: expected ${formatValue(expected)} but got ${formatValue(actual)}`);
  },
  assert_not_equals(actual, expected, description = '') {
    assert(!sameValue(actual, expected), `${description}: got the disallowed value ${formatValue(actual)}`);
  },
  assert_true(actual, description = '') { assert(actual === true, `${description}: expected true`); },
  assert_false(actual, description = '') { assert(actual === false, `${description}: expected false`); },
  assert_array_equals(actual, expected, description = '') {
    assert(actual.length === expected.length, `${description}: lengths differ, expected ${expected.length} got ${actual.length}`);
    for (let index = 0; index < actual.length; index++) {
      assert(sameValue(actual[index], expected[index]), `${description}: index ${index} expected ${formatValue(expected[index])} got ${formatValue(actual[index])}`);
    }
  },
  assert_throws_js(constructor, func, description = '') {
    try {
      func();
    } catch (error) {
      assert(error instanceof constructor || (error && error.name === constructor.name),
        `${description}: threw ${error && error.name}, expected ${constructor.name}`);
      return;
    }
    throw new AssertionError(`${description}: did not throw ${constructor.name}`);
  },
  format_value: formatValue,
  setup(func) { if (typeof func === "function") func(); },
  done() {},
  test(func, name) {
    try {
      func({ step_func: f => f, add_cleanup() {} });
      results.push([currentFile, name, 'PASS', '']);
    } catch (error) {
      results.push([currentFile, name, 'FAIL', String(error && error.message || error)]);
    }
  },
async_test(func, name) {
  let settle;
  pendingPromises.push(new Promise(resolve => { settle = resolve; }));
  const record = (result, message) => { results.push([currentFile, name, result, message]); settle(); };
  const t = {
    step_func_done: f => (...args) => {
      try { f(...args); record("PASS", ""); } catch (error) { record("FAIL", String(error && error.message || error)); }
    },
    step_func: f => f,
    done: () => record("PASS", ""),
  };
  try { func(t); } catch (error) { record("FAIL", String(error && error.message || error)); }
},
promise_test(func, name) {
    pendingPromises.push(Promise.resolve().then(() => func({})).then(
      () => results.push([currentFile, name, 'PASS', '']),
      error => results.push([currentFile, name, 'FAIL', String(error && error.message || error)])));
  },
  subsetTest(testFunction, ...args) { return testFunction(...args); },
  // /common/sab.js
  createBuffer(type, length, options) {
    if (type === 'SharedArrayBuffer') return new SharedArrayBuffer(length, options);
    return new ArrayBuffer(length, options);
  },
};

function metaScripts(file, source) {
  const list = [];
  for (const line of source.split('\n')) {
    const match = /^\/\/ META: script=(.*)$/.exec(line.trim());
    if (!match) continue;
    const script = match[1].trim();
    if (script.startsWith('/common/') || script.startsWith('/resources/')) continue; // provided by the harness
    list.push(path.join(path.dirname(file), script));
  }
  return list;
}

async function run() {
  for (const entry of FILES) {
    const [file, search = ''] = entry.split('?');
    currentFile = entry;
    const fullPath = path.join(ROOT, file);
    const source = fs.readFileSync(fullPath, 'utf8');
    const context = vm.createContext({
      ...harness,
      TextDecoder: MicaTextDecoder,
      TextEncoder: MicaTextEncoder,
      XMLHttpRequest: MicaXMLHttpRequest,
      location: { search: search ? '?' + search : '' },
      Uint8Array, Uint16Array, Int8Array, Uint8ClampedArray, Int16Array, Int32Array, Uint32Array,
      Float32Array, Float64Array, DataView, ArrayBuffer, SharedArrayBuffer, BigInt64Array, BigUint64Array,
      Promise, Error, TypeError, RangeError, String, Array, Object, Math, JSON, setImmediate, console,
    });
    context.self = context;
    context.globalThis = context;
    const before = results.length;
    for (const script of metaScripts(fullPath, source)) {
      vm.runInContext(fs.readFileSync(script, 'utf8'), context, { filename: script });
    }
    vm.runInContext(source, context, { filename: fullPath });
    await Promise.all(pendingPromises);
    pendingPromises = [];
    const fileResults = results.slice(before);
    const passed = fileResults.filter(row => row[2] === 'PASS').length;
    console.log(`${String(passed).padStart(5)} / ${String(fileResults.length).padEnd(5)} ${entry}`);
  }
}

run().then(() => {
  const passed = results.filter(row => row[2] === 'PASS').length;
  console.log(`TOTAL ${passed} / ${results.length} subtests passed, ${results.length - passed} failed (${client.calls} oracle calls)`);
  for (const row of results.filter(row => row[2] === 'FAIL').slice(0, 40)) console.log('FAIL', row[0], '|', row[1], '|', row[3]);
  if (reportPath) fs.writeFileSync(reportPath, 'file\tsubtest\tresult\tmessage\n' + results.map(row => row.map(cell => String(cell).replace(/[\t\n]/g, ' ')).join('\t')).join('\n') + '\n');
  client.close();
  process.exit(passed === results.length ? 0 : 1);
}, error => {
  console.error(error);
  client.close();
  process.exit(2);
});

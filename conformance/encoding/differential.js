// Differential test of Mica::Encoding against two independent oracles:
//
// 1. The web-platform-tests reference implementations of the legacy
//    multi-byte decoders and encoders (legacy-mb-*/*-decoder.js and
//    *-encoder.js, written from the Encoding Standard by its test authors)
//    and the single-byte indexes in resources/single-byte-decoder.js.
// 2. ICU, through Node's built-in TextDecoder, for every web encoding it
//    supports. ICU is not a WHATWG implementation everywhere: a case where
//    ICU and the WPT reference disagree is counted as an ICU divergence,
//    not a Mica one.
//
//   SEED=1234 CASES=100000 node conformance/encoding/differential.js path/to/encoding_oracle [report.json]
//
// Exits non-zero when Mica disagrees with a WPT reference, or with ICU on
// a case the WPT reference does not explain.
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { OracleClient } = require('./oracle_client');

const WPT = path.resolve(__dirname, '..', 'encoding-vectors', 'wpt');
const [oraclePath, reportPath] = process.argv.slice(2);
const SEED = process.env.SEED ? Number(process.env.SEED) >>> 0 : (Date.now() >>> 0);
const CASES = Number(process.env.CASES || 100000);
const BATCH = 2000;
console.log(`seed ${SEED}, ${CASES} cases per encoding and direction`);

function prng(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const random = prng(SEED);
const pick = list => list[Math.floor(random() * list.length)];
const between = (low, high) => low + Math.floor(random() * (high - low + 1));

const client = new OracleClient(oraclePath);

function loadReference(files) {
  const context = vm.createContext({ console, String, Math, parseInt, Array });
  for (const file of files) vm.runInContext(fs.readFileSync(path.join(WPT, file), 'utf8'), context, { filename: file });
  return context;
}

const REFERENCES = {
  Shift_JIS: { dir: 'legacy-mb-japanese/shift_jis', files: ['jis0208_index.js', 'sjis-decoder.js', 'sjis-encoder.js'], decoder: 'sjisDecoder', encoder: 'sjisEncoder', index: 'jis0208' },
  'EUC-JP': { dir: 'legacy-mb-japanese/euc-jp', files: ['jis0208_index.js', 'jis0212_index.js', 'eucjp-decoder.js', 'eucjp-encoder.js'], decoder: 'eucjpDecoder', encoder: 'eucjpEncoder', index: 'jis0208' },
  'ISO-2022-JP': { dir: 'legacy-mb-japanese/iso-2022-jp', files: ['jis0208_index.js', 'iso2022jp-decoder.js', 'iso2022jp-encoder.js'], decoder: 'iso2022jpDecoder', encoder: 'iso2022jpEncoder', index: 'jis0208' },
  'EUC-KR': { dir: 'legacy-mb-korean/euc-kr', files: ['euckr_index.js', 'euckr-decoder.js', 'euckr-encoder.js'], decoder: 'euckrDecoder', encoder: 'euckrEncoder', index: 'euckr' },
  Big5: { dir: 'legacy-mb-tchinese/big5', files: ['big5_index.js', 'big5-decoder.js', 'big5-encoder.js'], decoder: 'big5Decoder', encoder: 'big5Encoder', index: 'big5' },
};

const EDGE_BYTES = [0x00, 0x0e, 0x0f, 0x1b, 0x24, 0x28, 0x30, 0x39, 0x40, 0x42, 0x49, 0x4a, 0x5c, 0x7e, 0x7f, 0x80,
  0x81, 0x8e, 0x8f, 0x9f, 0xa0, 0xa1, 0xc0, 0xc1, 0xc2, 0xdf, 0xe0, 0xed, 0xef, 0xf0, 0xf4, 0xf5, 0xfc, 0xfd, 0xfe, 0xff];

function randomBytes(name) {
  const length = between(0, 48);
  const bytes = [];
  while (bytes.length < length) {
    const roll = random();
    if (name === 'ISO-2022-JP' && roll < 0.15) {
      bytes.push(...pick([[0x1b, 0x28, 0x42], [0x1b, 0x28, 0x4a], [0x1b, 0x28, 0x49], [0x1b, 0x24, 0x40], [0x1b, 0x24, 0x42], [0x1b, 0x28], [0x1b, 0x24], [0x1b]]));
    } else if (roll < 0.35) {
      bytes.push(between(0x20, 0x7e));
    } else if (roll < 0.85) {
      bytes.push(name === 'ISO-2022-JP' ? between(0x21, 0x7e) : between(0x80, 0xff));
    } else {
      bytes.push(pick(EDGE_BYTES));
    }
  }
  return bytes;
}

function randomCodePoints(index) {
  const length = between(0, 16);
  const codePoints = [];
  const specials = [0xa5, 0x203e, 0x2212, 0xff61, 0xff9f, 0xff70, 0x0e, 0x0f, 0x1b, 0x5c, 0x7e, 0x80, 0x20ac, 0xe5e5, 0xca, 0xea, 0x304, 0x30c, 0x2550, 0x5341, 0xfffd];
  while (codePoints.length < length) {
    const roll = random();
    if (roll < 0.3) codePoints.push(between(0x20, 0x7e));
    else if (roll < 0.7 && index) {
      const value = index[Math.floor(random() * index.length)];
      if (value != null) codePoints.push(value);
    } else if (roll < 0.85) {
      const value = between(0x80, 0xffff);
      if (value < 0xd800 || value > 0xdfff) codePoints.push(value);
    } else if (roll < 0.95) codePoints.push(pick(specials));
    else codePoints.push(between(0x10000, 0x10ffff));
  }
  return codePoints;
}

const toHex = bytes => bytes.map(byte => byte.toString(16).toUpperCase().padStart(2, '0')).join(' ');
const fromCodePoints = codePoints => codePoints.map(codePoint => String.fromCodePoint(codePoint)).join('');
const codePointsOf = text => Array.from(text).map(char => char.codePointAt(0));
const sameArray = (a, b) => a.length === b.length && a.every((value, index) => value === b[index]);

const report = { seed: SEED, cases: CASES, reference: {}, icu: {} };
let failures = 0;

function micaDecode(label, inputs) {
  const outputs = [];
  for (let start = 0; start < inputs.length; start += BATCH) {
    outputs.push(...client.ask({ op: 'decode_batch', label, inputs: inputs.slice(start, start + BATCH) }).outputs);
  }
  return outputs;
}
function micaEncode(label, inputs) {
  const outputs = [];
  for (let start = 0; start < inputs.length; start += BATCH) {
    outputs.push(...client.ask({ op: 'encode_batch', label, inputs: inputs.slice(start, start + BATCH) }).outputs);
  }
  return outputs;
}

// --- 1. WPT reference implementations --------------------------------------
const referenceDecodeCache = {};
for (const [name, reference] of Object.entries(REFERENCES)) {
  const context = loadReference(reference.files.map(file => path.join(reference.dir, file)));
  const decodeInputs = Array.from({ length: CASES }, () => randomBytes(name));
  const micaDecoded = micaDecode(name, decodeInputs);
  const decodeRow = { cases: CASES, disagreements: 0, examples: [] };
  referenceDecodeCache[name] = { inputs: decodeInputs, outputs: [] };
  decodeInputs.forEach((bytes, caseIndex) => {
    // The reference decoders read "" as one bad byte (parseInt("") is NaN).
    const expected = bytes.length === 0 ? [] : codePointsOf(context[reference.decoder](toHex(bytes)));
    referenceDecodeCache[name].outputs.push(expected);
    if (!sameArray(expected, micaDecoded[caseIndex])) {
      decodeRow.disagreements++;
      if (decodeRow.examples.length < 5) decodeRow.examples.push({ bytes: toHex(bytes), reference: expected, mica: micaDecoded[caseIndex] });
    }
  });
  const index = context[reference.index];
  const encodeInputs = Array.from({ length: CASES }, () => randomCodePoints(index));
  const micaEncoded = micaEncode(name, encodeInputs);
  const encodeRow = { cases: CASES, disagreements: 0, examples: [] };
  encodeInputs.forEach((codePoints, caseIndex) => {
    const result = context[reference.encoder](fromCodePoints(codePoints));
    const expected = result === null ? null : result.trim() === '' ? '' : result.trim().split(/\s+/).map(hex => hex.padStart(2, '0')).join(' ');
    const mica = micaEncoded[caseIndex] === null ? null : toHex(micaEncoded[caseIndex]);
    if (expected !== mica) {
      encodeRow.disagreements++;
      if (encodeRow.examples.length < 5) encodeRow.examples.push({ code_points: codePoints.map(c => c.toString(16)), reference: expected, mica });
    }
  });
  report.reference[name] = { decode: decodeRow, encode: encodeRow };
  failures += decodeRow.disagreements + encodeRow.disagreements;
  for (const example of decodeRow.examples.slice(0, 3)) console.log('  decode example', JSON.stringify(example));
  for (const example of encodeRow.examples.slice(0, 3)) console.log('  encode example', JSON.stringify(example));
  console.log(`WPT reference ${name.padEnd(12)} decode ${decodeRow.disagreements} / ${CASES} disagree, encode ${encodeRow.disagreements} / ${CASES} disagree`);
}

// Single-byte: the reference is index single-byte from WPT's own copy.
const singleByteContext = loadReference(['resources/encodings.js', 'resources/single-byte-decoder.js'].filter(file => fs.existsSync(path.join(WPT, file))));
const singleByteIndexes = vm.runInContext('typeof singleByteIndexes === "undefined" ? {} : singleByteIndexes', singleByteContext);
for (const [name, table] of Object.entries(singleByteIndexes)) {
  const inputs = Array.from({ length: Math.min(CASES, 20000) }, () => randomBytes(name));
  const mica = micaDecode(name, inputs);
  const row = { cases: inputs.length, disagreements: 0, examples: [] };
  inputs.forEach((bytes, caseIndex) => {
    const expected = bytes.map(byte => (byte < 0x80 ? byte : table[byte - 0x80] == null ? 0xfffd : table[byte - 0x80]));
    if (!sameArray(expected, mica[caseIndex])) {
      row.disagreements++;
      if (row.examples.length < 5) row.examples.push({ bytes: toHex(bytes), reference: expected, mica: mica[caseIndex] });
    }
  });
  referenceDecodeCache[name] = { inputs, outputs: inputs.map(bytes => bytes.map(byte => (byte < 0x80 ? byte : table[byte - 0x80] == null ? 0xfffd : table[byte - 0x80]))) };
  report.reference[name] = { decode: row };
  failures += row.disagreements;
}
console.log(`WPT reference single-byte: ${Object.keys(singleByteIndexes).length} encodings, ${Object.values(report.reference).filter(row => !row.encode).reduce((sum, row) => sum + row.decode.disagreements, 0)} disagreements`);

// --- 2. ICU through Node's TextDecoder ---------------------------------------
const encodingsContext = loadReference(['resources/encodings.js']);
const names = [];
for (const section of vm.runInContext('encodings_table', encodingsContext)) for (const encoding of section.encodings) names.push(encoding.name);
for (const name of names) {
  if (name === 'replacement') continue;
  let icu;
  try {
    icu = new TextDecoder(name);
  } catch {
    report.icu[name] = { supported: false };
    console.log(`ICU ${name.padEnd(15)} not supported by this Node build`);
    continue;
  }
  // The Encoding Standard defines GBK's decoder as gb18030's, so ICU's
  // gb18030 decoder is the reference for GBK.
  if (name === 'GBK' && !referenceDecodeCache.GBK) {
    const gbkInputs = Array.from({ length: CASES }, () => randomBytes(name));
    referenceDecodeCache.GBK = { inputs: gbkInputs, outputs: gbkInputs.map(bytes => codePointsOf(new TextDecoder('gb18030', { ignoreBOM: true }).decode(Uint8Array.from(bytes)))) };
  }
  const cached = referenceDecodeCache[name];
  const inputs = cached ? cached.inputs : Array.from({ length: CASES }, () => randomBytes(name));
  const mica = micaDecode(name, inputs);
  const row = { supported: true, cases: inputs.length, agree: 0, icu_differs_from_whatwg_reference: 0, unexplained: 0, examples: [] };
  inputs.forEach((bytes, caseIndex) => {
    const expected = codePointsOf(new TextDecoder(name, { ignoreBOM: true }).decode(Uint8Array.from(bytes)));
    if (sameArray(expected, mica[caseIndex])) {
      row.agree++;
    } else if (cached && !sameArray(expected, cached.outputs[caseIndex])) {
      row.icu_differs_from_whatwg_reference++;
    } else {
      row.unexplained++;
      if (row.examples.length < 5) row.examples.push({ bytes: toHex(bytes), icu: expected, mica: mica[caseIndex] });
    }
  });
  report.icu[name] = row;
  failures += row.unexplained;
  console.log(`ICU ${name.padEnd(15)} agree ${row.agree} / ${row.cases}, ICU differs from the WPT reference ${row.icu_differs_from_whatwg_reference}, unexplained ${row.unexplained}`);
}

client.close();
console.log(`seed ${SEED}: ${failures} unexplained disagreements`);
if (reportPath) fs.writeFileSync(reportPath, JSON.stringify(report, null, 1));
process.exit(failures === 0 ? 0 : 1);

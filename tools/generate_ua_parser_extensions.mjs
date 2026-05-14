import fs from "node:fs";
import vm from "node:vm";

const upstream = process.argv[2] ?? "/tmp/ua-parser-js-2.0.9/src/extensions/ua-parser-extensions.js";
const output = process.argv[3] ?? "src/ua_parser_extension_tables.zig";

const source = fs.readFileSync(upstream, "utf8");
const context = { module: { exports: {} } };
context.exports = context.module.exports;
vm.createContext(context);
vm.runInContext(`${source}
globalThis.__ua_ext = {
  Bots, CLIs, Crawlers, ExtraDevices, Emails, Fetchers, InApps, Libraries, MediaPlayers, Vehicles,
  normalizeEmailName
};`, context);

const ext = context.__ua_ext;
const functionNames = new Map([
  [ext.normalizeEmailName, "normalize_email_name"],
]);

function isRegExp(value) {
  return Object.prototype.toString.call(value) === "[object RegExp]";
}

function zigString(value) {
  if (value === undefined || value === null) return "null";
  const str = String(value);
  let out = '"';
  for (const ch of str) {
    const code = ch.codePointAt(0);
    if (ch === "\\") out += "\\\\";
    else if (ch === '"') out += '\\"';
    else if (ch === "\n") out += "\\n";
    else if (ch === "\r") out += "\\r";
    else if (ch === "\t") out += "\\t";
    else if (code >= 0x20 && code <= 0x7e) out += ch;
    else if (code <= 0xff) out += `\\x${code.toString(16).padStart(2, "0")}`;
    else throw new Error(`Non-ASCII table value is not supported: ${str}`);
  }
  return out + '"';
}

function fieldName(name) {
  switch (name) {
    case "name":
    case "version":
    case "major":
    case "type":
    case "vendor":
    case "model":
    case "architecture":
      return `.${name}`;
    default:
      throw new Error(`Unknown field: ${name}`);
  }
}

let mapperId = 0;
const mapperDecls = [];

function emitMapper(map, label) {
  const name = `mapper_${label}_${mapperId++}`.replace(/[^a-zA-Z0-9_]/g, "_");
  const entries = [];
  let defaultValue = null;
  let hasDefault = false;
  for (const [out, rawInputs] of Object.entries(map)) {
    if (out === "*") {
      hasDefault = true;
      defaultValue = rawInputs;
      continue;
    }
    const inputs = Array.isArray(rawInputs) ? rawInputs : [rawInputs];
    const outValue = out === "?" ? "null" : zigString(out);
    entries.push(`        .{ .out = ${outValue}, .inputs = &.{ ${inputs.map(zigString).join(", ")} } },`);
  }
  mapperDecls.push(`const ${name} = Mapper{
    .entries = &.{
${entries.join("\n")}
    },
    .has_default = ${hasDefault},
    .default = ${defaultValue === undefined || defaultValue === null ? "null" : zigString(defaultValue)},
};`);
  return name;
}

function funcName(fn) {
  const name = functionNames.get(fn);
  if (!name && String(fn).includes("os == 'A'")) return ".whatsapp_os";
  if (!name) throw new Error(`Unsupported function transform: ${fn}`);
  return `.${name}`;
}

function replacement(regexp, replacement) {
  return `.{
        .pattern = ${zigString(regexp.source)},
        .replacement = ${zigString(replacement ?? "")},
        .global = ${Boolean(regexp.global)},
        .caseless = ${Boolean(regexp.ignoreCase)},
    }`;
}

function emitProp(prop, label, propIdx) {
  if (!Array.isArray(prop)) {
    return `.{ .field = ${fieldName(prop)}, .kind = .capture }`;
  }

  const [key, second, third, fourth, ...rest] = prop;
  const field = fieldName(key);

  if (prop.length === 2) {
    if (typeof second === "function") {
      return `.{ .field = ${field}, .kind = .func, .func = ${funcName(second)} }`;
    }
    if (second === undefined) return `.{ .field = ${field}, .kind = .static_null }`;
    return `.{ .field = ${field}, .kind = .static, .value = ${zigString(second)} }`;
  }

  if (typeof second === "function") {
    const mapper = emitMapper(third, `${label}_${propIdx}`);
    return `.{ .field = ${field}, .kind = .func, .func = ${funcName(second)}, .mapper = &${mapper} }`;
  }

  if (!isRegExp(second)) throw new Error(`Unsupported transform in ${label}/${propIdx}`);
  if (prop.length === 3) {
    return `.{ .field = ${field}, .kind = .replace, .replace = ${replacement(second, third)} }`;
  }

  if (typeof fourth !== "function") throw new Error(`Unsupported replace function in ${label}/${propIdx}`);
  const mapper = rest.length > 0 ? emitMapper(rest[0], `${label}_${propIdx}`) : null;
  return `.{ .field = ${field}, .kind = .replace_func, .replace = ${replacement(second, third)}, .func = ${funcName(fourth)}, .mapper = ${mapper ? `&${mapper}` : "null"} }`;
}

function emitRule(label, regexes, props) {
  const patterns = regexes.map((r) => {
    if (!isRegExp(r)) throw new Error(`Expected RegExp in ${label}`);
    if (!r.ignoreCase) throw new Error(`Unsupported match flags ${r.flags} in ${label}`);
    return zigString(r.source);
  });
  return `    .{
        .patterns = &.{ ${patterns.join(", ")} },
        .props = &.{
            ${props.map((prop, idx) => emitProp(prop, label, idx)).join(",\n            ")}
        },
    },`;
}

function emitRules(name, category, arr) {
  if (!arr) return `pub const ${name}_${category}_rules = [_]Rule{};`;
  const rules = [];
  for (let i = 0; i < arr.length; i += 2) {
    rules.push(emitRule(`${name}_${category}_${i / 2}`, arr[i], arr[i + 1]));
  }
  return `pub const ${name}_${category}_rules = [_]Rule{
${rules.join("\n")}
};`;
}

const names = [
  ["bots", ext.Bots],
  ["clis", ext.CLIs],
  ["crawlers", ext.Crawlers],
  ["extra_devices", ext.ExtraDevices],
  ["emails", ext.Emails],
  ["fetchers", ext.Fetchers],
  ["inapps", ext.InApps],
  ["libraries", ext.Libraries],
  ["mediaplayers", ext.MediaPlayers],
  ["vehicles", ext.Vehicles],
];

const header = `// Generated by tools/generate_ua_parser_extensions.mjs from ua-parser-js v2.0.9.
// Do not edit by hand.

const base = @import("ua_parser_tables.zig");
const Rule = base.Rule;
const Mapper = base.Mapper;
`;

const chunks = [header];
for (const [name, value] of names) {
  for (const category of ["browser", "cpu", "device", "engine", "os"]) {
    chunks.push(emitRules(name, category, value[category]));
  }
}
chunks.push(...mapperDecls);

fs.writeFileSync(output, chunks.join("\n\n"));

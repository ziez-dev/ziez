import fs from "node:fs";
import vm from "node:vm";

const upstream = process.argv[2] ?? "/tmp/ua-parser-js-2.0.9/src/main/ua-parser.js";
const output = process.argv[3] ?? "src/ua_parser_tables.zig";

const source = fs.readFileSync(upstream, "utf8");
const start = source.indexOf("    var windowsVersionMap =");
const end = source.indexOf("    /////////////////\n    // Factories", start);
if (start < 0 || end < 0) {
  throw new Error("Unable to locate ua-parser-js regex map section");
}

const prelude = `
var TYPEOF={FUNCTION:'function',OBJECT:'object',STRING:'string',UNDEFINED:'undefined'};
var EMPTY='',UNKNOWN='?',NAME='name',TYPE='type',VENDOR='vendor',VERSION='version',ARCHITECTURE='architecture',MAJOR='major',MODEL='model';
var CONSOLE='console',MOBILE='mobile',TABLET='tablet',SMARTTV='smarttv',WEARABLE='wearable',XR='xr',EMBEDDED='embedded';
var FETCHER='fetcher',INAPP='inapp';
var AMAZON='Amazon',APPLE='Apple',ASUS='ASUS',BLACKBERRY='BlackBerry',GOOGLE='Google',HUAWEI='Huawei',LENOVO='Lenovo',HONOR='Honor',LG='LG',MICROSOFT='Microsoft',MOTOROLA='Motorola',NVIDIA='Nvidia',ONEPLUS='OnePlus',OPPO='OPPO',SAMSUNG='Samsung',SHARP='Sharp',SONY='Sony',XIAOMI='Xiaomi',ZEBRA='Zebra';
var CHROME='Chrome',CHROMIUM='Chromium',CHROMECAST='Chromecast',EDGE='Edge',FIREFOX='Firefox',OPERA='Opera',FACEBOOK='Facebook',SOGOU='Sogou';
var PREFIX_MOBILE='Mobile ',SUFFIX_BROWSER=' Browser',WINDOWS='Windows';
var isString=function(val){return typeof val===TYPEOF.STRING;};
var lowerize=function(str){return isString(str)?str.toLowerCase():str;};
var strip=function(pattern,str){return isString(str)?str.replace(pattern,EMPTY):str;};
var trim=function(str,len){str=strip(/^\\s\\s*/, String(str)); return typeof len===TYPEOF.UNDEFINED?str:str.substring(0,len);};
var has=function(str1,str2){return false;};
var strMapper=function(str,map){return str;};
`;

const context = {};
vm.createContext(context);
vm.runInContext(prelude + source.slice(start, end), context);

const functionNames = new Map([
  [context.lowerize, "lowerize"],
  [context.trim, "trim"],
  [context.strMapper, "str_mapper"],
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

function emitProp(prop, cat, ruleIdx, propIdx) {
  if (!Array.isArray(prop)) {
    return `.{ .field = ${fieldName(prop)}, .kind = .capture }`;
  }

  const [key, second, third, fourth, ...rest] = prop;
  const field = fieldName(key);

  if (prop.length === 2) {
    if (typeof second === "function") {
      return `.{ .field = ${field}, .kind = .func, .func = ${funcName(second)} }`;
    }
    if (second === undefined) {
      return `.{ .field = ${field}, .kind = .static_null }`;
    }
    return `.{ .field = ${field}, .kind = .static, .value = ${zigString(second)} }`;
  }

  if (typeof second === "function") {
    const mapper = second === context.strMapper ? emitMapper(third, `${cat}_${ruleIdx}_${propIdx}`) : null;
    return `.{ .field = ${field}, .kind = .func, .func = ${funcName(second)}, .mapper = ${mapper ? `&${mapper}` : "null"} }`;
  }

  if (!isRegExp(second)) {
    throw new Error(`Unsupported transform in ${cat}/${ruleIdx}/${propIdx}`);
  }

  if (prop.length === 3) {
    return `.{ .field = ${field}, .kind = .replace, .replace = ${replacement(second, third)} }`;
  }

  if (typeof fourth !== "function") {
    throw new Error(`Unsupported replace function in ${cat}/${ruleIdx}/${propIdx}`);
  }
  const mapper = fourth === context.strMapper ? emitMapper(rest[0], `${cat}_${ruleIdx}_${propIdx}`) : null;
  return `.{ .field = ${field}, .kind = .replace_func, .replace = ${replacement(second, third)}, .func = ${funcName(fourth)}, .mapper = ${mapper ? `&${mapper}` : "null"} }`;
}

function emitRule(cat, idx, regexes, props) {
  const patterns = regexes.map((r) => {
    if (!isRegExp(r)) throw new Error(`Expected RegExp in ${cat}/${idx}`);
    if (r.flags !== "i") throw new Error(`Unsupported match flags ${r.flags} in ${cat}/${idx}`);
    return zigString(r.source);
  });
  const propValues = props.map((prop, propIdx) => emitProp(prop, cat, idx, propIdx));
  return `    .{
        .patterns = &.{ ${patterns.join(", ")} },
        .props = &.{
            ${propValues.join(",\n            ")}
        },
    },`;
}

function emitCategory(cat) {
  const arr = context.defaultRegexes[cat];
  const rules = [];
  for (let i = 0; i < arr.length; i += 2) {
    rules.push(emitRule(cat, i / 2, arr[i], arr[i + 1]));
  }
  return `pub const ${cat}_rules = [_]Rule{
${rules.join("\n")}
};`;
}

const header = `// Generated by tools/generate_ua_parser_tables.mjs from ua-parser-js v2.0.9.
// Do not edit by hand.

pub const Field = enum { name, version, major, type, vendor, model, architecture };
pub const Function = enum { lowerize, trim, str_mapper, normalize_email_name, whatsapp_os };
pub const PropKind = enum { capture, static, static_null, func, replace, replace_func };

pub const Replace = struct {
    pattern: []const u8,
    replacement: []const u8,
    global: bool = false,
    caseless: bool = false,
};

pub const MapEntry = struct {
    out: ?[]const u8,
    inputs: []const []const u8,
};

pub const Mapper = struct {
    entries: []const MapEntry,
    has_default: bool = false,
    default: ?[]const u8 = null,
};

pub const Prop = struct {
    field: Field,
    kind: PropKind,
    value: []const u8 = "",
    func: Function = .lowerize,
    replace: Replace = .{ .pattern = "", .replacement = "" },
    mapper: ?*const Mapper = null,
};

pub const Rule = struct {
    patterns: []const []const u8,
    props: []const Prop,
};
`;

const body = [
  header,
  ...["browser", "cpu", "device", "engine", "os"].map(emitCategory),
  ...mapperDecls,
].join("\n\n");

fs.mkdirSync(output.split("/").slice(0, -1).join("/") || ".", { recursive: true });
fs.writeFileSync(output, body);

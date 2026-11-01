const fs = require("fs");
const version = fs.readFileSync("version.txt", "utf8").trim();
fs.writeFileSync("built.js", `module.exports = ${JSON.stringify(`prepared with semver output ${version}`)};\n`);

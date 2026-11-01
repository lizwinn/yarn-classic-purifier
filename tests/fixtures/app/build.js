const fs = require("fs");
const isOdd = require("is-odd");
fs.mkdirSync("dist", { recursive: true });
fs.writeFileSync(
  "dist/message.js",
  `module.exports = ${JSON.stringify(`hello-yarn: built by the build script (3 is odd: ${isOdd(3)})`)};\n`,
);

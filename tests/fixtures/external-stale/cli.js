#!/usr/bin/env node
console.log(require("left-pad")("git", 5, ".") + " " + require("pad-left")("tarball", 9, "."));

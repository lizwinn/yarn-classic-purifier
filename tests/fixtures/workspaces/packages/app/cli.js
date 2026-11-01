#!/usr/bin/env node
const chalk = require("chalk");
const greet = require("@fixture/greet");
console.log(chalk.green(greet(process.argv[2] || "world")));

// A synchronous client for conformance/encoding/oracle.cr over two FIFOs,
// shared by wpt_runner.js and differential.js.
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, execFileSync } = require('child_process');

class OracleClient {
  constructor(oraclePath) {
    this.directory = fs.mkdtempSync(path.join(os.tmpdir(), 'mica-oracle-'));
    const requestFifo = path.join(this.directory, 'request');
    const responseFifo = path.join(this.directory, 'response');
    execFileSync('mkfifo', [requestFifo, responseFifo]);
    this.process = spawn(oraclePath, [requestFifo, responseFifo], { stdio: 'inherit' });
    this.requestFd = fs.openSync(requestFifo, 'w');
    this.responseFd = fs.openSync(responseFifo, 'r');
    this.pending = '';
    this.buffer = Buffer.alloc(1 << 20);
    this.calls = 0;
  }

  ask(request) {
    this.calls++;
    fs.writeSync(this.requestFd, JSON.stringify(request) + '\n');
    for (;;) {
      const newline = this.pending.indexOf('\n');
      if (newline >= 0) {
        const line = this.pending.slice(0, newline);
        this.pending = this.pending.slice(newline + 1);
        const response = JSON.parse(line);
        if (response.message) throw new Error('oracle: ' + response.message);
        return response;
      }
      const count = fs.readSync(this.responseFd, this.buffer, 0, this.buffer.length, null);
      if (count === 0) throw new Error('oracle closed its output');
      this.pending += this.buffer.toString('utf8', 0, count);
    }
  }

  close() {
    fs.closeSync(this.requestFd);
    this.process.kill();
    fs.rmSync(this.directory, { recursive: true, force: true });
  }
}

module.exports = { OracleClient };

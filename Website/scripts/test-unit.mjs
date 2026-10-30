import {readdirSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
const tests = readdirSync(new URL('../tests/', import.meta.url))
  .filter(name => !name.startsWith('._') && name.endsWith('.test.mjs') && !name.endsWith('-browser.test.mjs'))
  .sort().map(name => `tests/${name}`);
const result = spawnSync(process.execPath, ['--test', ...tests], {stdio: 'inherit'});
process.exit(result.status ?? 1);

// Builds Shield/resources.json: the scriptlets filter lists call by name
// (`##+js(json-prune, ...)`) — uBlock Origin's and Brave's — in the form
// Brave's engine reads. The same steps Brave's own packager takes
// (brave-core-crx-packager, lib/adBlockRustUtils.js).
//
//   node Shield/resources.mjs <uBlock checkout> <brave adblock-resources checkout>
import fs from 'fs'
import path from 'path'
import { pathToFileURL } from 'url'

const [ubo, brave] = process.argv.slice(2)
const { builtinScriptlets } = await import(
  pathToFileURL(path.join(ubo, 'src/js/resources/scriptlets.js')).href
)

const names = new Set(builtinScriptlets.map(s => s.name))
for (const s of builtinScriptlets) {
  for (const dep of s.dependencies ?? []) {
    if (!names.has(dep)) console.warn(`uBO scriptlet ${s.name} is missing ${dep}`)
  }
}

const out = builtinScriptlets.map(s => ({
  name: s.name,
  aliases: s.aliases ?? [],
  kind: { mime: 'application/javascript' },
  content: Buffer.from(s.fn.toString()).toString('base64'),
  dependencies: s.dependencies ?? [],
  // Trusted scriptlets only for lists that are trusted with them — which,
  // as in Brave, is all of the default ones.
  ...(s.requiresTrust ? { permission: 1 } : {}),
}))
out.push(...JSON.parse(fs.readFileSync(path.join(brave, 'dist/resources.json'), 'utf8')))

const target = path.join(path.dirname(new URL(import.meta.url).pathname), 'resources.json')
fs.writeFileSync(target, JSON.stringify(out))
console.log(`${out.length} resources -> ${target}`)

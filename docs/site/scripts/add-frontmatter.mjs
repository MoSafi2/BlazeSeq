#!/usr/bin/env node
/**
 * Add Starlight frontmatter (title) to Modo-generated API markdown files
 * that don't already have frontmatter.
 */
import { readdir, readFile, writeFile, access } from 'fs/promises';
import { constants } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const contentDir = join(__dirname, '..', 'src', 'content', 'docs', 'api');

function deriveTitle(relativePath, baseName) {
  if (baseName === '_index.md') {
    const segment = relativePath.split('/').filter(Boolean).pop() || 'API';
    return segment.charAt(0).toUpperCase() + segment.slice(1).replace(/-/g, ' ');
  }
  return baseName.replace(/\.md$/, '').replace(/_/g, ' ');
}

async function walk(dir, relativeDir = '') {
  const entries = await readdir(dir, { withFileTypes: true });
  for (const e of entries) {
    const full = join(dir, e.name);
    const rel = relativeDir ? `${relativeDir}/${e.name}` : e.name;
    if (e.isDirectory()) {
      await walk(full, rel);
    } else if (e.name.endsWith('.md')) {
      let content = await readFile(full, 'utf-8');
      if (content.startsWith('---')) continue;
      const title = deriveTitle(rel, e.name);
      const frontmatter = `---
title: ${title}
---

`;
      await writeFile(full, frontmatter + content);
    }
  }
}

async function main() {
  try {
    await access(contentDir, constants.R_OK);
  } catch (err) {
    if (err.code === 'ENOENT') {
      console.error(
        `Error: API directory not found at ${contentDir}. ` +
          "Ensure 'modo build' completed successfully."
      );
    } else {
      console.error(err);
    }
    process.exit(1);
  }
  await walk(contentDir);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

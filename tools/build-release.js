#!/usr/bin/env node
/*
 * build-release.js
 * ----------------
 * Bundles the Qwesty addon into a distributable zip containing only the files
 * WoW needs to run it: every root *.lua, the *.toc, and README.md.
 *
 * Files are nested under a top-level "Qwesty/" folder inside the archive so the
 * zip extracts straight into Interface/AddOns the way WoW expects, and the zip
 * is named "Qwesty-<version>-<interface>.zip" using the ## Version and
 * ## Interface lines from the .toc.
 *
 * The zip is written with a tiny self-contained writer (Node's zlib + a CRC32
 * table), so this script has no npm dependencies.
 *
 * Usage:
 *   node tools/build-release.js            # writes Qwesty-<version>-<interface>.zip into builds/
 *   node tools/build-release.js -o dist    # writes it into ./dist instead
 */

'use strict';

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const ADDON_NAME = 'Qwesty';
const ROOT = path.resolve(__dirname, '..');

// ---------------------------------------------------------------------------
// Minimal ZIP writer (deflate, no dependencies)
// ---------------------------------------------------------------------------

const CRC_TABLE = (() => {
    const t = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
        let c = n;
        for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
        t[n] = c >>> 0;
    }
    return t;
})();

function crc32(buf) {
    let c = 0xFFFFFFFF;
    for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xFF] ^ (c >>> 8);
    return (c ^ 0xFFFFFFFF) >>> 0;
}

function dosTime(d) {
    return ((d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1)) & 0xFFFF;
}

function dosDate(d) {
    return ((((d.getFullYear() - 1980) & 0x7F) << 9) | ((d.getMonth() + 1) << 5) | d.getDate()) & 0xFFFF;
}

// entries: [{ name, data (Buffer), mtime (Date) }] -> Buffer of the whole zip.
function buildZip(entries) {
    const chunks = [];
    const central = [];
    let offset = 0;

    for (const e of entries) {
        const nameBuf = Buffer.from(e.name, 'utf8');
        const compressed = zlib.deflateRawSync(e.data);
        const crc = crc32(e.data);
        const time = dosTime(e.mtime);
        const date = dosDate(e.mtime);

        const local = Buffer.alloc(30);
        local.writeUInt32LE(0x04034b50, 0);  // local file header signature
        local.writeUInt16LE(20, 4);           // version needed to extract
        local.writeUInt16LE(0x0800, 6);       // flags: bit 11 = UTF-8 names
        local.writeUInt16LE(8, 8);            // method: deflate
        local.writeUInt16LE(time, 10);
        local.writeUInt16LE(date, 12);
        local.writeUInt32LE(crc, 14);
        local.writeUInt32LE(compressed.length, 18);
        local.writeUInt32LE(e.data.length, 22);
        local.writeUInt16LE(nameBuf.length, 26);
        local.writeUInt16LE(0, 28);           // extra field length

        chunks.push(local, nameBuf, compressed);

        const cd = Buffer.alloc(46);
        cd.writeUInt32LE(0x02014b50, 0);      // central directory header signature
        cd.writeUInt16LE(20, 4);              // version made by
        cd.writeUInt16LE(20, 6);              // version needed
        cd.writeUInt16LE(0x0800, 8);          // flags
        cd.writeUInt16LE(8, 10);              // method
        cd.writeUInt16LE(time, 12);
        cd.writeUInt16LE(date, 14);
        cd.writeUInt32LE(crc, 16);
        cd.writeUInt32LE(compressed.length, 20);
        cd.writeUInt32LE(e.data.length, 24);
        cd.writeUInt16LE(nameBuf.length, 28);
        cd.writeUInt16LE(0, 30);              // extra length
        cd.writeUInt16LE(0, 32);              // comment length
        cd.writeUInt16LE(0, 34);              // disk number start
        cd.writeUInt16LE(0, 36);              // internal attrs
        cd.writeUInt32LE(0, 38);              // external attrs
        cd.writeUInt32LE(offset, 42);         // offset of local header
        central.push(Buffer.concat([cd, nameBuf]));

        offset += local.length + nameBuf.length + compressed.length;
    }

    const centralBuf = Buffer.concat(central);
    const end = Buffer.alloc(22);
    end.writeUInt32LE(0x06054b50, 0);         // end of central directory signature
    end.writeUInt16LE(0, 4);                  // disk number
    end.writeUInt16LE(0, 6);                  // disk with central dir
    end.writeUInt16LE(entries.length, 8);     // entries on this disk
    end.writeUInt16LE(entries.length, 10);    // total entries
    end.writeUInt32LE(centralBuf.length, 12); // central dir size
    end.writeUInt32LE(offset, 16);            // central dir offset
    end.writeUInt16LE(0, 20);                 // comment length

    return Buffer.concat([...chunks, centralBuf, end]);
}

// ---------------------------------------------------------------------------
// Collect the files to ship
// ---------------------------------------------------------------------------

function readVersion(tocPath) {
    const m = fs.readFileSync(tocPath, 'utf8').match(/^##\s*Version:\s*(.+?)\s*$/mi);
    if (!m) throw new Error(`No "## Version:" line found in ${path.basename(tocPath)}`);
    return m[1];
}

// A .toc may target several clients at once ("## Interface: 120005, 120007").
// The zip is named after the newest client it supports, so take the highest.
function readInterface(tocPath) {
    const toc = path.basename(tocPath);
    const m = fs.readFileSync(tocPath, 'utf8').match(/^##\s*Interface:\s*(.+?)\s*$/mi);
    if (!m) throw new Error(`No "## Interface:" line found in ${toc}`);

    const values = m[1].split(',').map((v) => v.trim()).filter(Boolean);
    if (values.length === 0) throw new Error(`Empty "## Interface:" line in ${toc}`);

    const bad = values.find((v) => !/^\d+$/.test(v));
    if (bad) throw new Error(`Non-numeric interface version "${bad}" in ${toc}`);

    return values.reduce((a, b) => (Number(b) > Number(a) ? b : a));
}

function main() {
    const argv = process.argv.slice(2);
    let outDir = path.join(ROOT, 'builds');
    const oi = argv.findIndex((a) => a === '-o' || a === '--out');
    if (oi !== -1) {
        if (!argv[oi + 1]) throw new Error('-o/--out requires a directory argument');
        outDir = path.resolve(argv[oi + 1]);
    }

    const rootFiles = fs.readdirSync(ROOT).filter((f) => fs.statSync(path.join(ROOT, f)).isFile());
    const tocFiles = rootFiles.filter((f) => f.toLowerCase().endsWith('.toc'));
    if (tocFiles.length === 0) throw new Error('No .toc file found in the addon root');

    const shipped = rootFiles.filter((f) =>
        f.toLowerCase().endsWith('.lua') ||
        f.toLowerCase().endsWith('.toc') ||
        f.toLowerCase() === 'readme.md'
    );

    const tocPath = path.join(ROOT, tocFiles[0]);
    const version = readVersion(tocPath);
    const iface = readInterface(tocPath);
    const entries = shipped.map((f) => {
        const full = path.join(ROOT, f);
        return { name: `${ADDON_NAME}/${f}`, data: fs.readFileSync(full), mtime: fs.statSync(full).mtime };
    });

    const zipName = `${ADDON_NAME}-${version}-${iface}.zip`;
    fs.mkdirSync(outDir, { recursive: true });
    const outPath = path.join(outDir, zipName);
    fs.writeFileSync(outPath, buildZip(entries));

    console.log(`Built ${zipName} (${entries.length} files):`);
    for (const e of entries) console.log(`  ${e.name}`);
    console.log(`\nWrote ${outPath}`);
}

try {
    main();
} catch (err) {
    console.error(`build-release: ${err.message}`);
    process.exit(1);
}

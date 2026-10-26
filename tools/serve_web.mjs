#!/usr/bin/env node
// 本地 Web 版静态服务器：支持 gzip，方便在 iPad/手机浏览器里测试 58MB 的 Web 构建。
// 用法：node tools/serve_web.mjs [root] [port]
// 默认 root=build/web，port=8090。

import { createServer } from "node:http";
import { createReadStream, statSync } from "node:fs";
import { createGzip } from "node:zlib";
import { extname, join, normalize, resolve, sep } from "node:path";
import { networkInterfaces } from "node:os";

const root = resolve(process.argv[2] || "build/web");
const port = Number(process.argv[3] || 8090);

const MIME = {
	".html": "text/html; charset=utf-8",
	".js": "application/javascript; charset=utf-8",
	".mjs": "application/javascript; charset=utf-8",
	".wasm": "application/wasm",
	".pck": "application/octet-stream",
	".png": "image/png",
	".jpg": "image/jpeg",
	".jpeg": "image/jpeg",
	".svg": "image/svg+xml",
	".json": "application/json; charset=utf-8",
	".css": "text/css; charset=utf-8",
	".ico": "image/x-icon",
};

const COMPRESSIBLE = new Set([".html", ".js", ".mjs", ".wasm", ".pck", ".json", ".css", ".svg"]);

function lanAddresses() {
	const out = [];
	for (const list of Object.values(networkInterfaces())) {
		for (const addr of list || []) {
			if (addr.family === "IPv4" && !addr.internal) out.push(addr.address);
		}
	}
	return out;
}

const server = createServer((req, res) => {
	try {
		const url = new URL(req.url || "/", "http://localhost");
		let pathname = decodeURIComponent(url.pathname);
		if (pathname.endsWith("/")) pathname += "index.html";
		const filePath = resolve(join(root, normalize(pathname).replace(/^[/\\]+/, "")));
		if (filePath !== root && !filePath.startsWith(root + sep)) {
			res.writeHead(403, { "Content-Type": "text/plain; charset=utf-8" });
			res.end("Forbidden");
			return;
		}
		const stat = statSync(filePath);
		if (!stat.isFile()) throw new Error("not a file");
		const ext = extname(filePath).toLowerCase();
		const headers = {
			"Content-Type": MIME[ext] || "application/octet-stream",
			"Cache-Control": "no-cache",
			"Cross-Origin-Opener-Policy": "same-origin",
			"Cross-Origin-Embedder-Policy": "require-corp",
		};
		const acceptsGzip = /\bgzip\b/.test(req.headers["accept-encoding"] || "");
		if (acceptsGzip && COMPRESSIBLE.has(ext)) {
			headers["Content-Encoding"] = "gzip";
			headers["Vary"] = "Accept-Encoding";
		}
		res.writeHead(200, headers);
		if (req.method === "HEAD") {
			res.end();
			return;
		}
		const stream = createReadStream(filePath);
		if (headers["Content-Encoding"] === "gzip") {
			stream.pipe(createGzip({ level: 9 })).pipe(res);
		} else {
			stream.pipe(res);
		}
	} catch (err) {
		res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
		res.end("Not Found: " + (req.url || "/"));
	}
});

server.listen(port, "0.0.0.0", () => {
	console.log(`Web build root: ${root}`);
	console.log(`Local:  http://localhost:${port}/FingerEmpire.html`);
	for (const ip of lanAddresses()) {
		console.log(`LAN:    http://${ip}:${port}/FingerEmpire.html`);
	}
	console.log("Ctrl+C to stop.");
});

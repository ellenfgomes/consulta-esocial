#!/usr/bin/env bash
set -euo pipefail

mkdir -p public xml-entrada data certs .devcontainer .github/workflows

cat > .devcontainer/devcontainer.json <<'EOF'
{
  "containerEnv": {
    "HOST": "0.0.0.0"
  },
  "forwardPorts": [3000],
  "portsAttributes": {
    "3000": {
      "label": "Painel eSocial S-2210",
      "visibility": "private",
      "onAutoForward": "openBrowser"
    }
  }
}
EOF

cat > .github/workflows/pages.yml <<'EOF'
name: Publish GitHub Pages preview

on:
  push:
    branches:
      - main
    paths:
      - "public/**"
      - ".github/workflows/pages.yml"
  workflow_dispatch:

concurrency:
  group: github-pages
  cancel-in-progress: true

jobs:
  build:
    permissions:
      contents: read
      pages: write
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Configure GitHub Pages
        uses: actions/configure-pages@v5
        with:
          enablement: true
      - name: Upload static site
        uses: actions/upload-pages-artifact@v3
        with:
          path: public
  deploy:
    needs: build
    permissions:
      actions: read
      pages: write
      id-token: write
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    runs-on: ubuntu-latest
    steps:
      - name: Deploy site
        id: deployment
        uses: actions/deploy-pages@v4
EOF

cat > package.json <<'EOF'
{
  "name": "esocial-s2210-cat",
  "version": "1.0.0",
  "private": true,
  "description": "API para ingestão e consulta exclusiva de eventos eSocial S-2210 (CAT).",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "dev": "node --watch server.js",
    "check": "node --check server.js && node --check public/app.js"
  },
  "engines": {
    "node": ">=20"
  },
  "dependencies": {
    "bcryptjs": "^2.4.3",
    "better-sqlite3": "^11.8.1",
    "chokidar": "^4.0.3",
    "cors": "^2.8.5",
    "dotenv": "^16.4.7",
    "express": "^4.21.2",
    "express-rate-limit": "^7.5.0",
    "fast-xml-parser": "^4.5.3",
    "helmet": "^8.0.0",
    "jsonwebtoken": "^9.0.2",
    "multer": "^2.0.2",
    "node-forge": "^1.3.1",
    "xml-crypto": "^6.0.1"
  }
}
EOF

cat > .env.example <<'EOF'
NODE_ENV=development
PORT=3000
HOST=127.0.0.1
TRUST_PROXY=0
DATABASE_PATH=./data/esocial.sqlite
XML_INPUT_DIR=./xml-entrada
UPLOAD_DIR=./data/uploads

# Gere uma chave forte e um hash: node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
API_KEY=REPLACE_WITH_A_RANDOM_SECRET
# Gere o hash de senha com: node -e "require('bcryptjs').hash(process.argv[1], 12).then(console.log)" "SuaSenhaForte"
ADMIN_PASSWORD_HASH=REPLACE_WITH_BCRYPT_HASH
JWT_SECRET=REPLACE_WITH_ANOTHER_RANDOM_SECRET
JWT_EXPIRES_IN=8h

# O CORS aceita qualquer origem por padrão. Restrinja em produção, ex.: https://painel.exemplo.com
CORS_ORIGINS=*
# Habilite consulta do painel sem login somente em Codespaces com porta privada.
PANEL_QUERY_AUTH_DISABLED=true

# Integração SOAP só funciona após configuração com os dados do ambiente eSocial habilitado.
ESOCIAL_SOAP_ENDPOINT=
ESOCIAL_SOAP_ACTION=
ESOCIAL_SOAP_NAMESPACE=
ESOCIAL_PFX_PATH=./certs/empresa.pfx
ESOCIAL_PFX_PASSPHRASE=
ESOCIAL_EMPLOYER_TP_INSC=
ESOCIAL_EMPLOYER_NR_INSC=
EOF

if [[ ! -f .env ]]; then
  cp .env.example .env
fi

cat > .gitignore <<'EOF'
node_modules/
.env
data/*
!data/.gitkeep
certs/*
!certs/.gitkeep
xml-entrada/*
!xml-entrada/.gitkeep
EOF

touch data/.gitkeep certs/.gitkeep xml-entrada/.gitkeep

cat > server.js <<'EOF'
'use strict';

require('dotenv').config();
const fs = require('node:fs');
const path = require('node:path');
const https = require('node:https');
const crypto = require('node:crypto');
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const multer = require('multer');
const Database = require('better-sqlite3');
const chokidar = require('chokidar');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const forge = require('node-forge');
const { XMLParser, XMLValidator } = require('fast-xml-parser');
const { SignedXml } = require('xml-crypto');

const app = express();
const port = Number(process.env.PORT || 3000);
const host = process.env.HOST || '127.0.0.1';
const root = __dirname;
const resolveConfigPath = (value, fallback) => path.resolve(root, value || fallback);
const dbPath = resolveConfigPath(process.env.DATABASE_PATH, './data/esocial.sqlite');
const inputDir = resolveConfigPath(process.env.XML_INPUT_DIR, './xml-entrada');
const uploadDir = resolveConfigPath(process.env.UPLOAD_DIR, './data/uploads');
const maxXmlBytes = 2 * 1024 * 1024;
const cpfPattern = /^\d{11}$/;
const xmlParser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: '@_',
  textNodeName: '#text',
  removeNSPrefix: true,
  parseTagValue: false,
  trimValues: true
});

for (const directory of [path.dirname(dbPath), inputDir, uploadDir]) {
  fs.mkdirSync(directory, { recursive: true });
}

if (process.env.TRUST_PROXY === '1') app.set('trust proxy', 1);
app.disable('x-powered-by');
app.use(helmet());
const allowedOrigins = (process.env.CORS_ORIGINS || '*').split(',').map((item) => item.trim());
app.use(cors({
  origin(origin, callback) {
    if (!origin || allowedOrigins.includes('*') || allowedOrigins.includes(origin)) return callback(null, true);
    return callback(new Error('Origem não autorizada pelo CORS.'));
  }
}));
app.use(express.json({ limit: '2mb', type: ['application/json', 'application/*+json'] }));
app.use(express.text({ limit: '2mb', type: ['application/xml', 'text/xml'] }));
app.use(rateLimit({ windowMs: 15 * 60 * 1000, limit: 300, standardHeaders: 'draft-7', legacyHeaders: false }));

const db = new Database(dbPath);
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');
db.exec(`
  CREATE TABLE IF NOT EXISTS cat_esocial_s2210 (
    id_evento TEXT PRIMARY KEY,
    cpf TEXT NOT NULL,
    dt_acid TEXT,
    tp_acid TEXT,
    tp_cat TEXT,
    nr_rec_cat_orig TEXT,
    nr_recibo TEXT,
    cd_resposta TEXT,
    desc_resposta TEXT,
    status TEXT NOT NULL CHECK (status IN ('ENVIADO', 'ACEITO', 'ERRO', 'AGUARDANDO_RECIBO')),
    xml_origem TEXT,
    origem TEXT NOT NULL DEFAULT 'api',
    criado_em TEXT NOT NULL DEFAULT (datetime('now')),
    atualizado_em TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_cat_esocial_s2210_cpf ON cat_esocial_s2210(cpf);
  CREATE TABLE IF NOT EXISTS auditoria_lgpd (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ip TEXT NOT NULL,
    origem_requisicao TEXT,
    cpf_consultado TEXT NOT NULL,
    data_hora TEXT NOT NULL DEFAULT (datetime('now'))
  );
`);

const upsertCat = db.prepare(`
  INSERT INTO cat_esocial_s2210
    (id_evento, cpf, dt_acid, tp_acid, tp_cat, nr_rec_cat_orig, nr_recibo,
     cd_resposta, desc_resposta, status, xml_origem, origem)
  VALUES
    (@id_evento, @cpf, @dt_acid, @tp_acid, @tp_cat, @nr_rec_cat_orig, @nr_recibo,
     @cd_resposta, @desc_resposta, @status, @xml_origem, @origem)
  ON CONFLICT(id_evento) DO UPDATE SET
    cpf = excluded.cpf,
    dt_acid = COALESCE(excluded.dt_acid, cat_esocial_s2210.dt_acid),
    tp_acid = COALESCE(excluded.tp_acid, cat_esocial_s2210.tp_acid),
    tp_cat = COALESCE(excluded.tp_cat, cat_esocial_s2210.tp_cat),
    nr_rec_cat_orig = COALESCE(excluded.nr_rec_cat_orig, cat_esocial_s2210.nr_rec_cat_orig),
    nr_recibo = COALESCE(excluded.nr_recibo, cat_esocial_s2210.nr_recibo),
    cd_resposta = COALESCE(excluded.cd_resposta, cat_esocial_s2210.cd_resposta),
    desc_resposta = COALESCE(excluded.desc_resposta, cat_esocial_s2210.desc_resposta),
    status = excluded.status,
    xml_origem = COALESCE(excluded.xml_origem, cat_esocial_s2210.xml_origem),
    origem = excluded.origem,
    atualizado_em = datetime('now')
`);

function isValidCpf(value) {
  const cpf = String(value || '').replace(/\D/g, '');
  if (!cpfPattern.test(cpf) || /^(\d)\1{10}$/.test(cpf)) return false;
  for (let digit = 9; digit < 11; digit += 1) {
    let sum = 0;
    for (let i = 0; i < digit; i += 1) sum += Number(cpf[i]) * ((digit + 1) - i);
    const check = (sum * 10) % 11;
    if (Number(cpf[digit]) !== (check === 10 ? 0 : check)) return false;
  }
  return true;
}

function asText(value) {
  if (value === undefined || value === null) return null;
  if (typeof value === 'object') {
    if (value['#text'] !== undefined) return asText(value['#text']);
    return null;
  }
  const text = String(value).trim();
  return text || null;
}

function findValues(node, key, result = []) {
  if (!node || typeof node !== 'object') return result;
  if (Array.isArray(node)) {
    for (const item of node) findValues(item, key, result);
    return result;
  }
  for (const [name, value] of Object.entries(node)) {
    if (name === key) result.push(value);
    if (value && typeof value === 'object') findValues(value, key, result);
  }
  return result;
}

function findFirst(node, key) {
  return findValues(node, key).map(asText).find((value) => value !== null) || null;
}

function collectEvents(node, key, result = []) {
  if (!node || typeof node !== 'object') return result;
  if (Array.isArray(node)) {
    for (const item of node) collectEvents(item, key, result);
    return result;
  }
  for (const [name, value] of Object.entries(node)) {
    if (name === key) {
      if (Array.isArray(value)) result.push(...value);
      else result.push(value);
    }
    if (value && typeof value === 'object') collectEvents(value, key, result);
  }
  return result;
}

function idFromEvent(event) {
  if (!event || typeof event !== 'object') return null;
  return asText(event['@_Id'] || event.Id || event.id_evento);
}

function mapStatus(code, hasReceipt) {
  if (code === '201' || code === '202') return 'ACEITO';
  if (code) return 'ERRO';
  return hasReceipt ? 'ACEITO' : 'AGUARDANDO_RECIBO';
}

function parseCatEvent(event, rawXml, origem) {
  const id = idFromEvent(event);
  const cpf = findFirst(event, 'cpfTrab') || findFirst(event, 'cpf');
  if (!id) throw Object.assign(new Error('Evento S-2210 sem atributo Id.'), { status: 422 });
  if (!cpf || !isValidCpf(cpf)) throw Object.assign(new Error('CPF do trabalhador ausente ou inválido.'), { status: 422 });
  return {
    id_evento: id,
    cpf: String(cpf).replace(/\D/g, ''),
    dt_acid: findFirst(event, 'dtAcid'),
    tp_acid: findFirst(event, 'tpAcid'),
    tp_cat: findFirst(event, 'tpCat'),
    nr_rec_cat_orig: findFirst(event, 'nrRecCatOrig'),
    nr_recibo: findFirst(event, 'nrRecibo'),
    cd_resposta: findFirst(event, 'cdResposta'),
    desc_resposta: findFirst(event, 'descResposta'),
    status: 'ENVIADO',
    xml_origem: rawXml || null,
    origem
  };
}

function parseXml(xml) {
  if (typeof xml !== 'string' || !xml.trim()) {
    throw Object.assign(new Error('XML vazio. Envie somente eventos S-2210.'), { status: 400 });
  }
  const validation = XMLValidator.validate(xml);
  if (validation !== true) {
    throw Object.assign(new Error(`XML inválido: ${validation.err.msg}.`), { status: 400 });
  }
  try {
    return xmlParser.parse(xml);
  } catch (error) {
    throw Object.assign(new Error(`Não foi possível interpretar o XML: ${error.message}`), { status: 400 });
  }
}

function ingestXml(xml, origem) {
  const doc = parseXml(xml);
  const events = collectEvents(doc, 'evtCAT');
  const transaction = db.transaction(() => {
    const saved = [];
    for (const event of events) {
      const cat = parseCatEvent(event, xml, origem);
      const code = cat.cd_resposta;
      cat.status = mapStatus(code, Boolean(cat.nr_recibo));
      upsertCat.run(cat);
      saved.push(cat);
    }
    if (saved.length) return saved;

    const isBatchReturn = findValues(doc, 'retornoProcessamentoLoteEventos').length > 0;
    if (isBatchReturn) {
      const ids = [...new Set(findValues(doc, '@_Id').map(asText).filter(Boolean))];
      let updated = 0;
      for (const id of ids) {
        const existing = db.prepare('SELECT * FROM cat_esocial_s2210 WHERE id_evento = ?').get(id);
        if (!existing) continue;
        const response = {
          id_evento: existing.id_evento,
          cpf: existing.cpf,
          dt_acid: existing.dt_acid,
          tp_acid: existing.tp_acid,
          tp_cat: existing.tp_cat,
          nr_rec_cat_orig: existing.nr_rec_cat_orig,
          nr_recibo: findFirst(doc, 'nrRecibo'),
          cd_resposta: findFirst(doc, 'cdResposta'),
          desc_resposta: findFirst(doc, 'descResposta'),
          status: existing.status,
          xml_origem: xml,
          origem
        };
        response.status = mapStatus(response.cd_resposta, Boolean(response.nr_recibo));
        upsertCat.run(response);
        updated += 1;
      }
      if (updated) return [{ atualizados: updated }];
      throw Object.assign(
        new Error('Retorno recebido, mas nenhum Id corresponde a um S-2210 previamente enviado.'),
        { status: 422 }
      );
    }
    throw Object.assign(
      new Error('Evento eSocial não aceito: a API processa exclusivamente S-2210 (<evtCAT>).'),
      { status: 422 }
    );
  });
  return transaction();
}

function ingestJson(payload, origem) {
  const event = payload && (payload.evtCAT || payload.evento || payload);
  const id = event && (event['@_Id'] || event.Id || event.id_evento || event.idEvento);
  const cpf = event && (event.cpfTrab || event.cpf || event.trabalhador && event.trabalhador.cpf);
  const eventType = payload && (payload.tipoEvento || payload.eventType || payload.tipo_evento);
  if (eventType && eventType !== 'S-2210' && eventType !== 'evtCAT') {
    throw Object.assign(new Error('Evento eSocial não aceito: a API processa exclusivamente S-2210.'), { status: 422 });
  }
  const cat = parseCatEvent({
    '@_Id': id,
    cpfTrab: cpf,
    dtAcid: event && (event.dtAcid || event.dt_acid),
    tpAcid: event && (event.tpAcid || event.tp_acid),
    tpCat: event && (event.tpCat || event.tp_cat),
    nrRecCatOrig: event && (event.nrRecCatOrig || event.nr_rec_cat_orig),
    nrRecibo: event && (event.nrRecibo || event.nr_recibo),
    cdResposta: event && (event.cdResposta || event.cd_resposta),
    descResposta: event && (event.descResposta || event.desc_resposta)
  }, null, origem);
  cat.status = mapStatus(cat.cd_resposta, Boolean(cat.nr_recibo));
  upsertCat.run(cat);
  return [cat];
}

function safeEqual(a, b) {
  const left = Buffer.from(String(a || ''));
  const right = Buffer.from(String(b || ''));
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function apiKeyOrAdmin(req, res, next) {
  const apiKey = req.get('x-api-key');
  if (process.env.API_KEY && !process.env.API_KEY.startsWith('REPLACE_') && safeEqual(apiKey, process.env.API_KEY)) return next();
  const token = (req.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (token && process.env.JWT_SECRET && !process.env.JWT_SECRET.startsWith('REPLACE_')) {
    try {
      req.admin = jwt.verify(token, process.env.JWT_SECRET);
      return next();
    } catch { /* Continue to the explicit unauthorized response. */ }
  }
  return res.status(401).json({ erro: 'Autenticação necessária: informe x-api-key ou uma sessão administrativa válida.' });
}

function requireApiKey(req, res, next) {
  if (!process.env.API_KEY || process.env.API_KEY.startsWith('REPLACE_') || process.env.API_KEY.length < 32) {
    return res.status(503).json({ erro: 'API_KEY não configurada no ambiente.' });
  }
  if (!safeEqual(req.get('x-api-key'), process.env.API_KEY)) {
    return res.status(401).json({ erro: 'x-api-key ausente ou inválida.' });
  }
  return next();
}

function requirePrivatePanel(req, res, next) {
  if (process.env.PANEL_QUERY_AUTH_DISABLED !== 'true') {
    return res.status(403).json({ erro: 'Painel sem autenticação desabilitado; use a rota protegida por API key.' });
  }
  return next();
}

function recordAudit(req, cpf) {
  db.prepare(`
    INSERT INTO auditoria_lgpd (ip, origem_requisicao, cpf_consultado)
    VALUES (?, ?, ?)
  `).run(req.ip || req.socket.remoteAddress || 'desconhecido', req.get('origin') || req.get('referer') || null, cpf);
}

function normalizeCpf(value) {
  return String(value || '').replace(/\D/g, '');
}

function sendCatStatus(req, res) {
  const cpf = normalizeCpf(req.params.cpf);
  if (!isValidCpf(cpf)) return res.status(400).json({ erro: 'CPF inválido.' });
  recordAudit(req, cpf);
  const ocorrencias = db.prepare(`
    SELECT id_evento, dt_acid, tp_acid, tp_cat, nr_rec_cat_orig, nr_recibo,
           cd_resposta, desc_resposta, status, criado_em, atualizado_em
    FROM cat_esocial_s2210 WHERE cpf = ? ORDER BY criado_em DESC
  `).all(cpf);
  const possuiEnviada = ocorrencias.some((item) => ['ENVIADO', 'ACEITO', 'AGUARDANDO_RECIBO'].includes(item.status));
  const statusGeral = !ocorrencias.length ? 'NAO_ENVIADO' : possuiEnviada ? 'ENVIADO' : 'PENDENTE_OU_ERRO';
  return res.json({
    cpf,
    possui_cat_enviada: possuiEnviada,
    status_geral: statusGeral,
    total_ocorrencias: ocorrencias.length,
    cats: ocorrencias.map((item) => ({
      id_evento: item.id_evento,
      data_acidente: item.dt_acid,
      tipo_acidente: ({ '1': 'Típico', '2': 'Doença ocupacional', '3': 'Trajeto' })[item.tp_acid] || item.tp_acid,
      tipo_cat: ({ '1': 'Inicial', '2': 'Reabertura', '3': 'Comunicação de Óbito' })[item.tp_cat] || item.tp_cat,
      tp_cat: item.tp_cat,
      recibo_cat_origem: item.nr_rec_cat_orig,
      nr_recibo: item.nr_recibo,
      status: item.status,
      cd_resposta: item.cd_resposta,
      mensagem: item.desc_resposta
    }))
  });
}

app.get('/api/health', (_req, res) => res.json({ status: 'ok', evento: 'S-2210' }));

app.post('/api/login', rateLimit({ windowMs: 15 * 60 * 1000, limit: 10 }), async (req, res) => {
  const password = req.body && req.body.password;
  const hash = process.env.ADMIN_PASSWORD_HASH;
  if (!hash || hash.startsWith('REPLACE_') || !process.env.JWT_SECRET || process.env.JWT_SECRET.startsWith('REPLACE_')) {
    return res.status(503).json({ erro: 'Login não configurado. Defina ADMIN_PASSWORD_HASH e JWT_SECRET.' });
  }
  const valid = typeof password === 'string' && await bcrypt.compare(password, hash);
  if (!valid) return res.status(401).json({ erro: 'Usuário ou senha inválidos.' });
  const token = jwt.sign({ role: 'admin' }, process.env.JWT_SECRET, { expiresIn: process.env.JWT_EXPIRES_IN || '8h' });
  return res.json({ token, expires_in: process.env.JWT_EXPIRES_IN || '8h' });
});

app.get('/api/v1/s2210/status/:cpf', requireApiKey, sendCatStatus);
app.get('/api/painel/s2210/status/:cpf', requirePrivatePanel, sendCatStatus);

app.post('/api/v1/s2210/webhook', requireApiKey, (req, res, next) => {
  try {
    const contentType = (req.get('content-type') || '').toLowerCase();
    const records = contentType.includes('xml')
      ? ingestXml(req.body, 'webhook')
      : contentType.includes('json')
        ? ingestJson(req.body, 'webhook')
        : null;
    if (!records) return res.status(415).json({ erro: 'Content-Type aceito: application/xml ou application/json.' });
    return res.status(202).json({ mensagem: 'Processamento S-2210 concluído.', total: records.length, eventos: records });
  } catch (error) {
    return next(error);
  }
});

const storage = multer.diskStorage({
  destination: (_req, _file, callback) => callback(null, uploadDir),
  filename: (_req, file, callback) => callback(null, `${Date.now()}-${crypto.randomBytes(6).toString('hex')}.xml`)
});
const upload = multer({
  storage,
  limits: { fileSize: maxXmlBytes, files: 20 },
  fileFilter: (_req, file, callback) => {
    if (path.extname(file.originalname).toLowerCase() !== '.xml') return callback(new Error('Somente arquivos .xml são aceitos.'));
    callback(null, true);
  }
});

function processUploadFiles(files) {
  const results = [];
  for (const file of files) {
    try {
      const xml = fs.readFileSync(file.path, 'utf8');
      const saved = ingestXml(xml, 'upload');
      results.push({ arquivo: file.originalname, sucesso: true, total: saved.length });
    } catch (error) {
      results.push({ arquivo: file.originalname, sucesso: false, erro: error.message });
    } finally {
      fs.rmSync(file.path, { force: true });
    }
  }
  return results;
}

function handleXmlImport(req, res) {
  const files = req.files || [];
  if (!files.length) return res.status(400).json({ erro: 'Envie pelo menos um arquivo .xml no campo multipart "files".' });
  const results = processUploadFiles(files);
  return res.status(results.some((item) => !item.sucesso) ? 207 : 200).json({ resultados: results });
}

app.post('/api/v1/s2210/importar-xml', apiKeyOrAdmin, upload.array('files', 20), handleXmlImport);
app.post('/api/painel/s2210/importar-xml', requirePrivatePanel, upload.array('files', 20), handleXmlImport);

function escapeXml(value) {
  return String(value).replace(/[<>&'"]/g, (char) => ({
    '<': '&lt;', '>': '&gt;', '&': '&amp;', "'": '&apos;', '"': '&quot;'
  })[char]);
}

function buildSignedSoapRequest(cpf) {
  const required = ['ESOCIAL_SOAP_ENDPOINT', 'ESOCIAL_SOAP_ACTION', 'ESOCIAL_SOAP_NAMESPACE',
    'ESOCIAL_EMPLOYER_TP_INSC', 'ESOCIAL_EMPLOYER_NR_INSC', 'ESOCIAL_PFX_PASSPHRASE'];
  const missing = required.filter((name) => !process.env[name]);
  const pfxPath = resolveConfigPath(process.env.ESOCIAL_PFX_PATH, './certs/empresa.pfx');
  if (!fs.existsSync(pfxPath)) missing.push('ESOCIAL_PFX_PATH (arquivo .pfx)');
  if (missing.length) {
    throw Object.assign(new Error(`Integração eSocial não configurada: ${missing.join(', ')}.`), { status: 503 });
  }

  const pfx = fs.readFileSync(pfxPath);
  const asn1 = forge.asn1.fromDer(forge.util.createBuffer(pfx.toString('binary')));
  const p12 = forge.pkcs12.pkcs12FromAsn1(asn1, false, process.env.ESOCIAL_PFX_PASSPHRASE);
  const keyBag = p12.getBags({ bagType: forge.pki.oids.pkcs8ShroudedKeyBag })[forge.pki.oids.pkcs8ShroudedKeyBag] || [];
  const certBag = p12.getBags({ bagType: forge.pki.oids.certBag })[forge.pki.oids.certBag] || [];
  if (!keyBag[0] || !keyBag[0].key || !certBag[0] || !certBag[0].cert) {
    throw Object.assign(new Error('O PFX deve conter uma chave privada e o certificado correspondente.'), { status: 500 });
  }
  const privateKeyPem = forge.pki.privateKeyToPem(keyBag[0].key);
  const certificatePem = forge.pki.certificateToPem(certBag[0].cert);
  const certificateBase64 = certificatePem.replace(/-----BEGIN CERTIFICATE-----|-----END CERTIFICATE-----|\s/g, '');
  const namespace = escapeXml(process.env.ESOCIAL_SOAP_NAMESPACE);
  const tpInsc = escapeXml(process.env.ESOCIAL_EMPLOYER_TP_INSC);
  const nrInsc = escapeXml(process.env.ESOCIAL_EMPLOYER_NR_INSC);
  const request = `<eSocial xmlns="${namespace}"><consultaIdentificadoresEventosTrabalhador><ideEmpregador><tpInsc>${tpInsc}</tpInsc><nrInsc>${nrInsc}</nrInsc></ideEmpregador><ideTrabalhador><cpfTrab>${cpf}</cpfTrab></ideTrabalhador></consultaIdentificadoresEventosTrabalhador></eSocial>`;
  const soap = `<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Header/><soap:Body Id="consultaBody">${request}</soap:Body></soap:Envelope>`;
  const signer = new SignedXml({
    privateKey: privateKeyPem,
    getKeyInfoContent: () => `<X509Data><X509Certificate>${certificateBase64}</X509Certificate></X509Data>`
  });
  signer.addReference({
    xpath: "//*[local-name(.)='Body']",
    transforms: ['http://www.w3.org/2001/10/xml-exc-c14n#'],
    digestAlgorithm: 'http://www.w3.org/2001/04/xmlenc#sha256',
    uri: '#consultaBody'
  });
  signer.signatureAlgorithm = 'http://www.w3.org/2001/04/xmldsig-more#rsa-sha256';
  signer.canonicalizationAlgorithm = 'http://www.w3.org/2001/10/xml-exc-c14n#';
  signer.computeSignature(soap, { location: { reference: "//*[local-name(.)='Header']", action: 'append' } });
  return { xml: signer.getSignedXml(), pfx, action: process.env.ESOCIAL_SOAP_ACTION };
}

function soapPost({ xml, pfx, action }) {
  const endpoint = new URL(process.env.ESOCIAL_SOAP_ENDPOINT);
  if (endpoint.protocol !== 'https:') throw Object.assign(new Error('O endpoint SOAP deve usar HTTPS.'), { status: 503 });
  return new Promise((resolve, reject) => {
    const request = https.request(endpoint, {
      method: 'POST',
      pfx,
      passphrase: process.env.ESOCIAL_PFX_PASSPHRASE,
      headers: {
        'content-type': 'text/xml; charset=utf-8',
        SOAPAction: action,
        'content-length': Buffer.byteLength(xml)
      },
      timeout: 30000
    }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8');
        if (response.statusCode < 200 || response.statusCode >= 300) {
          return reject(Object.assign(new Error(`WebService eSocial respondeu HTTP ${response.statusCode}: ${body.slice(0, 1000)}`), { status: 502 }));
        }
        resolve(body);
      });
    });
    request.on('timeout', () => request.destroy(new Error('Tempo limite excedido no WebService eSocial.')));
    request.on('error', reject);
    request.end(xml);
  });
}

app.post('/api/v1/s2210/consultar-gov', apiKeyOrAdmin, async (req, res, next) => {
  try {
    const cpf = normalizeCpf(req.body && req.body.cpf);
    if (!isValidCpf(cpf)) return res.status(400).json({ erro: 'Informe um CPF válido no campo cpf.' });
    const { xml, pfx, action } = buildSignedSoapRequest(cpf);
    const responseXml = await soapPost({ xml, pfx, action });
    const parsed = parseXml(responseXml);
    const returnedEvents = collectEvents(parsed, 'evtCAT');
    let synchronized = 0;
    for (const event of returnedEvents) {
      const mapped = parseCatEvent(event, responseXml, 'consulta-gov');
      const receipt = findFirst(event, 'nrRecibo');
      mapped.nr_recibo = receipt;
      mapped.cd_resposta = findFirst(parsed, 'cdResposta');
      mapped.desc_resposta = findFirst(parsed, 'descResposta');
      mapped.status = mapStatus(mapped.cd_resposta, Boolean(receipt));
      upsertCat.run(mapped);
      synchronized += 1;
    }
    return res.json({
      mensagem: 'Consulta ao WebService concluída; somente eventos S-2210 foram sincronizados.',
      total_s2210_sincronizados: synchronized,
      eventos: returnedEvents.map((event) => ({ id_evento: idFromEvent(event), cpf }))
    });
  } catch (error) {
    return next(error);
  }
});

app.use(express.static(path.join(root, 'public'), {
  index: 'index.html',
  maxAge: process.env.NODE_ENV === 'production' ? '1h' : 0,
  setHeaders(response, filePath) {
    if (path.basename(filePath) === 'index.html') response.setHeader('Cache-Control', 'no-cache');
  }
}));

app.use((error, _req, res, _next) => {
  const status = Number(error.status || (error instanceof multer.MulterError ? 400 : 500));
  if (status >= 500) console.error('[erro]', error);
  return res.status(status).json({ erro: status >= 500 ? 'Erro interno ao processar a requisição.' : error.message });
});

const watcher = chokidar.watch(inputDir, { ignoreInitial: false, awaitWriteFinish: { stabilityThreshold: 500, pollInterval: 100 } });
watcher.on('add', (filePath) => {
  if (path.extname(filePath).toLowerCase() !== '.xml') return;
  try {
    const result = ingestXml(fs.readFileSync(filePath, 'utf8'), 'pasta-monitorada');
    console.info(`[xml-entrada] ${path.basename(filePath)}: ${result.length} registro(s) S-2210 processado(s).`);
  } catch (error) {
    console.error(`[xml-entrada] ${path.basename(filePath)}: ${error.message}`);
  }
});
watcher.on('error', (error) => console.error('[xml-entrada] erro no monitoramento:', error));

const server = app.listen(port, host, () => console.info(`API S-2210 disponível em http://${host}:${port}.`));
function shutdown() {
  watcher.close().catch((error) => console.error('Falha ao encerrar monitor:', error));
  server.close(() => {
    db.close();
    process.exit(0);
  });
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
EOF

cat > public/index.html <<'EOF'
<!doctype html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="Consulte eventos eSocial S-2210 (CAT) por CPF.">
  <title>Consulta CAT | eSocial S-2210</title>
  <link rel="stylesheet" href="./styles.css?v=3">
  <script defer src="./app.js?v=3"></script>
</head>
<body>
  <main class="shell">
    <header class="topbar">
      <a class="brand" href="./" aria-label="Página inicial">
        <span class="brand-mark" aria-hidden="true">CAT</span>
        <span class="brand-copy">eSocial <strong>S-2210</strong><small>Comunicação de Acidente de Trabalho</small></span>
      </a>
      <span class="privacy-pill"><span class="privacy-dot" aria-hidden="true"></span><span id="access-mode-label">Acesso privado</span></span>
    </header>

    <section class="hero" aria-labelledby="page-title">
      <div class="hero-copy">
        <p class="eyebrow">CONSULTA DE EVENTOS ESOCIAL</p>
        <h1 id="page-title">Consulte CATs<br><span>pelo CPF do trabalhador</span></h1>
        <p>Verifique o envio, o processamento e o recibo oficial de eventos S-2210.</p>
      </div>
      <div class="hero-mark" aria-hidden="true">
        <span class="hero-mark-symbol">✓</span>
        <span class="hero-mark-caption">S-2210<br>CAT</span>
      </div>
    </section>

    <aside id="static-preview-notice" class="static-preview-notice hidden" role="note">
      Prévia pública do layout. A consulta desta página estática não acessa dados reais; use o servidor local para consultar o banco S-2210.
    </aside>

    <section class="search-panel" aria-labelledby="search-title">
      <div class="section-heading">
        <span class="step-number">01</span>
        <div>
          <h2 id="search-title">Localizar trabalhador</h2>
          <p>Informe o CPF para consultar as ocorrências registradas.</p>
        </div>
      </div>
      <form id="search-form" class="search-form" novalidate>
        <label for="cpf-search">CPF do trabalhador</label>
        <div class="search-controls">
          <div class="cpf-input-wrap">
            <span class="input-icon" aria-hidden="true">#</span>
            <input id="cpf-search" name="cpf" type="text" inputmode="numeric" autocomplete="off"
              placeholder="000.000.000-00" maxlength="14" aria-describedby="cpf-help" required>
          </div>
          <button class="button button-primary" type="submit">
            <span>Consultar CPF</span><span aria-hidden="true">→</span>
          </button>
        </div>
        <div class="form-footer">
          <p id="cpf-help"><span aria-hidden="true">i</span> Aceita CPF com ou sem pontuação. Os dígitos verificadores serão validados.</p>
          <span class="privacy-note"><span aria-hidden="true">●</span> <span id="query-mode-label">Consulta privada</span></span>
        </div>
      </form>
    </section>

    <section class="results-section" aria-labelledby="results-title">
      <div class="results-heading">
        <div>
          <p class="eyebrow">RESULTADO DA BUSCA</p>
          <h2 id="results-title">Situação da CAT</h2>
        </div>
      </div>
      <div id="result" aria-live="polite" aria-atomic="true">
        <div class="empty-state">
          <span class="empty-icon" aria-hidden="true">⌕</span>
          <strong>Aguardando consulta</strong>
          <p>Digite um CPF válido acima para visualizar os eventos S-2210 encontrados.</p>
        </div>
      </div>
    </section>

    <footer id="data-note">Dados pessoais são tratados para consulta e auditoria LGPD. A API limita-se ao S-2210.</footer>
  </main>
</body>
</html>
EOF

cat > public/styles.css <<'EOF'
:root {
  color: #17233b;
  background: #f4f7fb;
  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  font-synthesis: none;
  text-rendering: optimizeLegibility;
}

* { box-sizing: border-box; }
body { margin: 0; min-width: 320px; }
button, input { font: inherit; }
.shell { max-width: 960px; margin: 0 auto; padding: 28px 24px 44px; }
.topbar { display: flex; align-items: center; justify-content: space-between; margin-bottom: 48px; }
.brand { display: flex; align-items: center; gap: 12px; color: inherit; text-decoration: none; }
.brand-mark { display: grid; width: 44px; height: 44px; place-items: center; border-radius: 14px; background: #e5efff; color: #155eef; font-size: 12px; font-weight: 850; }
.brand-copy { display: grid; grid-template-columns: auto auto; align-items: baseline; column-gap: 5px; font-size: 15px; }
.brand-copy small { grid-column: 1 / -1; margin-top: 3px; color: #778398; font-size: 11px; }
.privacy-pill { display: inline-flex; align-items: center; gap: 8px; padding: 8px 12px; border: 1px solid #dfe9e3; border-radius: 30px; background: #f3fbf5; color: #287044; font-size: 12px; font-weight: 700; }
.privacy-pill .privacy-dot, .privacy-note span { width: 7px; height: 7px; flex: 0 0 7px; border-radius: 50%; background: #28a45a; }
.hidden { display: none !important; }
.static-preview-notice { margin: -10px 0 24px; padding: 12px 15px; border: 1px solid #f0dfb8; border-radius: 10px; background: #fff8e9; color: #765317; font-size: 12px; line-height: 1.5; }
.hero { display: flex; min-height: 235px; align-items: center; justify-content: space-between; gap: 32px; margin-bottom: 26px; padding: 36px 42px; overflow: hidden; border-radius: 22px; background: linear-gradient(120deg, #102d58 0%, #174e93 100%); color: #fff; }
.hero-copy { max-width: 610px; }
.eyebrow { margin: 0 0 10px; color: #71aaff; font-size: 10px; font-weight: 850; letter-spacing: .15em; }
.hero h1 { margin: 0; font-size: clamp(29px, 4vw, 42px); line-height: 1.13; letter-spacing: -.04em; }
.hero h1 span { color: #b7d4ff; }
.hero-copy > p:last-child { max-width: 480px; margin: 15px 0 0; color: #d3e2f6; font-size: 14px; line-height: 1.6; }
.hero-mark { display: grid; width: 118px; height: 118px; flex: 0 0 118px; place-content: center; justify-items: center; border: 1px solid #ffffff3d; border-radius: 30px; background: #ffffff12; transform: rotate(5deg); }
.hero-mark-symbol { color: #8ed3a4; font-size: 47px; font-weight: 500; line-height: 1; }
.hero-mark-caption { margin-top: 6px; color: #eaf2ff; font-size: 10px; font-weight: 800; letter-spacing: .12em; text-align: center; }
.search-panel { padding: 28px 32px 22px; border: 1px solid #e4e9f1; border-radius: 18px; background: #fff; box-shadow: 0 14px 40px #20395a0d; }
.section-heading { display: flex; align-items: center; gap: 14px; margin-bottom: 24px; }
.step-number { display: grid; width: 38px; height: 38px; flex: 0 0 38px; place-items: center; border-radius: 12px; background: #edf4ff; color: #155eef; font-size: 12px; font-weight: 850; }
h2 { margin: 0; font-size: 20px; letter-spacing: -.02em; }
.section-heading p { margin: 5px 0 0; color: #758196; font-size: 13px; }
.search-form > label { display: block; margin-bottom: 9px; color: #35435a; font-size: 12px; font-weight: 750; }
.search-controls { display: flex; gap: 12px; }
.cpf-input-wrap { position: relative; flex: 1; }
.input-icon { position: absolute; top: 50%; left: 15px; color: #8b97a8; font-size: 20px; font-weight: 500; transform: translateY(-53%); }
.cpf-input-wrap input { width: 100%; height: 52px; padding: 0 14px 0 42px; border: 1px solid #d6deea; border-radius: 10px; outline: none; background: #fff; color: #17233b; font-size: 17px; letter-spacing: .04em; transition: border-color .15s, box-shadow .15s; }
.cpf-input-wrap input::placeholder { color: #a7b0be; }
.cpf-input-wrap input:focus { border-color: #3478ed; box-shadow: 0 0 0 4px #3478ed1c; }
.button { display: inline-flex; min-width: 158px; height: 52px; align-items: center; justify-content: center; gap: 16px; padding: 0 20px; border: 0; border-radius: 10px; cursor: pointer; font-size: 14px; font-weight: 750; transition: background .15s, transform .15s; }
.button-primary { background: #155eef; color: #fff; }
.button-primary:hover { background: #0e4bc4; }
.button:active { transform: translateY(1px); }
.button:disabled { cursor: wait; opacity: .65; }
.form-footer { display: flex; align-items: center; justify-content: space-between; gap: 14px; margin-top: 12px; }
.form-footer p { display: flex; align-items: center; gap: 8px; margin: 0; color: #758196; font-size: 11px; }
.form-footer p span { display: grid; width: 15px; height: 15px; place-items: center; border: 1px solid #aeb8c7; border-radius: 50%; font-size: 10px; font-weight: 700; }
.privacy-note { display: inline-flex; flex: 0 0 auto; align-items: center; gap: 6px; color: #4a7659; font-size: 11px; }
.privacy-note span { width: 6px; height: 6px; }
.results-section { margin: 38px 0 28px; }
.results-heading { margin: 0 0 15px; }
.results-heading .eyebrow { margin-bottom: 6px; color: #738099; }
.results-heading h2 { font-size: 21px; }
#result { min-height: 138px; }
.empty-state { display: flex; min-height: 138px; flex-direction: column; align-items: center; justify-content: center; padding: 24px; border: 1px dashed #cfd8e5; border-radius: 16px; background: #f9fbfe; text-align: center; }
.empty-icon { margin-bottom: 5px; color: #8ca2c0; font-size: 28px; line-height: 1; }
.empty-state strong { color: #47556b; font-size: 13px; }
.empty-state p { margin: 6px 0 0; color: #8590a1; font-size: 12px; }
.result-card { padding: 20px; border: 1px solid #e1e7ef; border-radius: 16px; background: #fff; box-shadow: 0 8px 26px #20395a0a; }
.result-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding-bottom: 15px; border-bottom: 1px solid #edf0f5; }
.result-head strong { color: #29364b; font-size: 14px; }
.badge { display: inline-flex; align-items: center; padding: 7px 11px; border-radius: 30px; background: #fff5e3; color: #8a5a00; font-size: 10px; font-weight: 850; letter-spacing: .04em; }
.badge.ok { background: #e9f8ee; color: #217341; }
.badge.error { background: #fff0ef; color: #a73930; }
.result-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 18px 22px; padding-top: 18px; }
.result-grid small { display: block; margin-bottom: 5px; color: #828da0; font-size: 10px; }
.result-grid strong { display: block; overflow-wrap: anywhere; color: #29364b; font-size: 12px; line-height: 1.45; }
.result-card > .muted { margin: 15px 0 0; color: #758196; font-size: 12px; }
code { font-family: ui-monospace, SFMono-Regular, Consolas, monospace; }
footer { padding-top: 20px; color: #8792a3; font-size: 10px; text-align: center; }

@media (max-width: 640px) {
  .shell { padding: 18px 16px 32px; }
  .topbar { margin-bottom: 26px; }
  .hero { min-height: 205px; padding: 27px 24px; border-radius: 18px; }
  .hero-mark { width: 78px; height: 78px; flex-basis: 78px; border-radius: 22px; }
  .hero-mark-symbol { font-size: 35px; }
  .hero-mark-caption { font-size: 8px; }
  .search-panel { padding: 22px 19px 18px; }
  .search-controls { flex-direction: column; }
  .button { width: 100%; }
  .form-footer { align-items: flex-start; flex-direction: column; }
  .result-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; }
}

@media (max-width: 420px) {
  .privacy-pill { padding: 7px 9px; font-size: 10px; }
  .brand-copy { font-size: 13px; }
  .brand-copy small { font-size: 9px; }
  .hero { padding: 25px 19px; }
  .hero h1 { font-size: 28px; }
  .hero-mark { display: none; }
  .result-head { align-items: flex-start; flex-direction: column; }
  .result-grid { grid-template-columns: 1fr 1fr; }
}
EOF

cat > public/app.js <<'EOF'
'use strict';

const isGithubPagesPreview = location.hostname.endsWith('.github.io');

async function consultarCpf(cpf) {
  if (isGithubPagesPreview) {
    throw new Error('Prévia estática: esta página não consulta dados reais. Use http://localhost:3000 para consultar o banco local.');
  }
  const response = await fetch(`/api/painel/s2210/status/${encodeURIComponent(cpf)}`);
  const data = await response.json().catch(() => ({}));
  if (response.status === 404) {
    throw new Error('API não encontrada. Inicie o servidor com "npm start" e abra a aplicação em http://localhost:3000.');
  }
  if (!response.ok) throw new Error(data.erro || `Falha HTTP ${response.status}`);
  return data;
}

if (isGithubPagesPreview) {
  document.querySelector('#access-mode-label').textContent = 'Prévia pública';
  document.querySelector('#static-preview-notice').classList.remove('hidden');
  document.querySelector('#cpf-help').textContent = 'Demonstração visual: nenhum CPF será enviado ou consultado nesta página pública.';
  document.querySelector('#query-mode-label').textContent = 'Somente demonstração';
  document.querySelector('#data-note').textContent = 'Esta prévia pública não consulta nem envia dados pessoais. A consulta real ocorre apenas no servidor local.';
}

function cpfValido(cpf) {
  if (!/^\d{11}$/.test(cpf) || /^(\d)\1{10}$/.test(cpf)) return false;
  for (let digit = 9; digit < 11; digit += 1) {
    let sum = 0;
    for (let i = 0; i < digit; i += 1) sum += Number(cpf[i]) * (digit + 1 - i);
    const check = (sum * 10) % 11;
    if (Number(cpf[digit]) !== (check === 10 ? 0 : check)) return false;
  }
  return true;
}

function mostrarMensagem(text) {
  const result = document.querySelector('#result');
  const message = document.createElement('div');
  message.className = 'empty-state';
  message.setAttribute('role', 'alert');
  const content = document.createElement('strong');
  content.textContent = text;
  message.append(content);
  result.replaceChildren(message);
}

function showResult(data) {
  const target = document.querySelector('#result');
  const cats = data.cats || [];
  const statuses = new Set(cats.map((cat) => cat.status));
  const accepted = statuses.has('ACEITO');
  const sent = statuses.has('ENVIADO');
  const pending = statuses.has('AGUARDANDO_RECIBO');
  const statusClass = accepted || sent ? 'ok' : pending ? '' : 'error';
  const statusLabel = accepted ? 'CAT ACEITA'
    : sent ? 'CAT ENVIADA'
      : pending ? 'AGUARDANDO RECIBO'
        : data.status_geral === 'PENDENTE_OU_ERRO' ? 'PENDENTE OU ERRO' : 'NÃO ENVIADA';
  target.replaceChildren();

  const card = document.createElement('article');
  card.className = 'result-card';
  const heading = document.createElement('div');
  heading.className = 'result-head';
  const title = document.createElement('strong');
  title.textContent = `${data.total_ocorrencias} ocorrência(s) de CAT`;
  const badge = document.createElement('span');
  badge.className = `badge ${statusClass}`;
  badge.textContent = statusLabel;
  heading.append(title, badge);
  card.append(heading);

  if (!cats.length) {
    const empty = document.createElement('p');
    empty.className = 'muted';
    empty.textContent = 'Nenhum evento S-2210 localizado para este CPF.';
    card.append(empty);
  }

  for (const cat of cats) {
    const details = document.createElement('div');
    details.className = 'result-grid';
    const values = [
      ['Data do acidente', cat.data_acidente || '—'],
      ['Tipo da CAT', cat.tipo_cat || '—'],
      ['Recibo oficial', cat.nr_recibo || 'Aguardando recibo'],
      ['Status', ({ ACEITO: 'Aceito', ENVIADO: 'Enviado', ERRO: 'Erro', AGUARDANDO_RECIBO: 'Aguardando recibo' })[cat.status] || cat.status],
      ['Tipo do acidente', cat.tipo_acidente || '—'],
      ['Mensagem', cat.mensagem || cat.cd_resposta || '—']
    ];
    for (const [label, value] of values) {
      const item = document.createElement('div');
      const caption = document.createElement('small');
      caption.textContent = label;
      const content = document.createElement('strong');
      content.textContent = value;
      item.append(caption, content);
      details.append(item);
    }
    card.append(details);
  }
  target.append(card);
}

document.querySelector('#cpf-search').addEventListener('input', (event) => {
  const digits = event.target.value.replace(/\D/g, '').slice(0, 11);
  event.target.value = digits
    .replace(/(\d{3})(\d)/, '$1.$2')
    .replace(/(\d{3})\.(\d{3})(\d)/, '$1.$2.$3')
    .replace(/(\d{3})\.(\d{3})\.(\d{3})(\d{1,2})$/, '$1.$2.$3-$4');
});

document.querySelector('#search-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const cpf = document.querySelector('#cpf-search').value.replace(/\D/g, '');
  const result = document.querySelector('#result');
  const button = event.currentTarget.querySelector('button[type="submit"]');
  if (!cpfValido(cpf)) {
    mostrarMensagem('Digite um CPF válido para consultar.');
    document.querySelector('#cpf-search').focus();
    return;
  }

  result.textContent = 'Consultando CPF...';
  button.disabled = true;
  try {
    showResult(await consultarCpf(cpf));
  } catch (error) {
    mostrarMensagem(error instanceof TypeError
      ? 'Não foi possível conectar à API. No terminal do projeto, execute "npm start" e abra http://localhost:3000.'
      : error.message);
  } finally {
    button.disabled = false;
  }
});
EOF

cat > xml-entrada/exemplo-s2210.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<eSocial xmlns="http://www.esocial.gov.br/schema/evt/evtCAT/v_S_01_03_00">
  <evtCAT Id="ID1000000000000002026011510300000001">
    <ideEvento>
      <indRetif>1</indRetif>
      <tpAmb>2</tpAmb>
      <procEmi>1</procEmi>
      <verProc>1.0</verProc>
    </ideEvento>
    <ideEmpregador>
      <tpInsc>1</tpInsc>
      <nrInsc>00000000000000</nrInsc>
    </ideEmpregador>
    <ideVinculo>
      <cpfTrab>52998224725</cpfTrab>
      <matricula>TESTE001</matricula>
      <codCateg>101</codCateg>
    </ideVinculo>
    <cat>
      <dtAcid>2026-01-15</dtAcid>
      <tpAcid>1</tpAcid>
      <hrAcid>10:30</hrAcid>
      <hrsTrabAntes>02:30</hrsTrabAntes>
      <tpCat>1</tpCat>
      <indCatObito>N</indCatObito>
      <indComunPolicia>N</indComunPolicia>
      <codSitGer>1</codSitGer>
      <iniciatCAT>1</iniciatCAT>
      <obsCAT>Exemplo didático para teste local; não transmitir à produção.</obsCAT>
      <localAcidente>
        <tpLocal>1</tpLocal>
        <dscLocal>Estabelecimento do empregador</dscLocal>
        <ideLocal>
          <tpInsc>1</tpInsc>
          <nrInsc>00000000000000</nrInsc>
        </ideLocal>
        <local>
          <dscLograd>Rua de teste</dscLograd>
          <nrLograd>100</nrLograd>
          <bairro>Centro</bairro>
          <cep>01001000</cep>
          <codMunic>3550308</codMunic>
          <uf>SP</uf>
        </local>
      </localAcidente>
      <parteAtingida>
        <codParte>753030000</codParte>
        <lateralidade>0</lateralidade>
      </parteAtingida>
      <agenteCausador>
        <codAgntCaus>200010000</codAgntCaus>
      </agenteCausador>
      <atestado>
        <dtAtendimento>2026-01-15</dtAtendimento>
        <hrAtendimento>11:00</hrAtendimento>
        <indInternacao>N</indInternacao>
        <durTrat>1</durTrat>
        <indAfast>N</indAfast>
        <dscLesao>Contusão leve</dscLesao>
        <diagProv>Contusão</diagProv>
        <codCID>S900</codCID>
        <emitente>
          <nmEmit>Profissional de Saúde Exemplo</nmEmit>
          <ideOC>1</ideOC>
          <nrOC>000000</nrOC>
          <ufOC>SP</ufOC>
        </emitente>
      </atestado>
    </cat>
  </evtCAT>
</eSocial>
EOF

cat > README.md <<'EOF'
# API eSocial S-2210 (CAT)

Aplicação Node.js/Express com SQLite para ingestão e consulta exclusiva de `evtCAT` (S-2210), executável localmente no Windows e no GitHub Codespaces. Requer Node.js 20+.

## Inicialização

```bash
npm install
npm start
```

Execute os comandos na pasta do projeto. No Windows, abra o PowerShell nessa pasta; se `node` ou `npm` não forem reconhecidos, instale Node.js 20 LTS e reinicie o terminal. Copie `.env.example` para `.env` apenas se ainda não existir um `.env`; mantenha `PANEL_QUERY_AUTH_DISABLED=true` para a consulta sem senha.

Localmente, o servidor escuta apenas em `127.0.0.1`; abra **http://localhost:3000**. Não use `python -m http.server`: ele serve os arquivos da página, mas não executa a API de consulta. No Codespaces, o `.devcontainer/devcontainer.json` configura `HOST=0.0.0.0` e a porta 3000 privada. A consulta grava auditoria de IP, origem e CPF. Para um ambiente público, defina `PANEL_QUERY_AUTH_DISABLED=false` e use a rota externa protegida por API key.

## Prévia no GitHub Pages

O workflow publica automaticamente a pasta `public/` em https://ellenfgomes.github.io/consulta-esocial/ após cada alteração nela. Essa URL é somente uma prévia estática do layout: por segurança, não consulta CPF nem contém dados da base local. Para consultas reais, use o servidor Node local em `http://localhost:3000`.

O banco SQLite é criado automaticamente. Para webhooks e integrações externas, configure `API_KEY`; para rotas administrativas protegidas, configure também `JWT_SECRET` e `ADMIN_PASSWORD_HASH`. Em produção restrinja `CORS_ORIGINS` e configure `TRUST_PROXY=1` apenas quando houver proxy confiável.

## Teste imediato

Depois de preencher `.env`, importe o exemplo:

```bash
curl -F "files=@xml-entrada/exemplo-s2210.xml" http://localhost:3000/api/painel/s2210/importar-xml
curl http://localhost:3000/api/painel/s2210/status/52998224725
```

O exemplo é didático, usa CPF de teste e identificadores/dados fictícios; não representa CAT válida para transmissão ao eSocial. O parser extrai os campos necessários, mas não substitui a validação do XML contra os XSD oficiais da versão S-1.3.

## Integração com WebService oficial

`POST /api/v1/s2210/consultar-gov` monta um envelope SOAP 1.1, assina o `Body` com XMLDSig RSA-SHA256/X.509, apresenta o PFX por mTLS e sincroniza somente os nós `evtCAT` recebidos. Configure `ESOCIAL_SOAP_ENDPOINT`, `ESOCIAL_SOAP_ACTION`, `ESOCIAL_SOAP_NAMESPACE`, `ESOCIAL_EMPLOYER_TP_INSC`, `ESOCIAL_EMPLOYER_NR_INSC`, `ESOCIAL_PFX_PATH` e `ESOCIAL_PFX_PASSPHRASE` de acordo com o WSDL/XSD e as regras do ambiente eSocial em que a empresa está habilitada (produção ou produção restrita). Certifique-se de que o certificado PFX é válido e contém chave/certificado compatíveis. O endpoint e a estrutura da operação variam com o contrato oficial; valide assinatura e payload em homologação antes de produção. Nenhum endpoint governamental é presumido ou codificado.

## Rotas

- `GET /api/v1/s2210/status/:cpf`: consulta CPF válido, protegida por `x-api-key`; gera registro em `auditoria_lgpd`.
- `GET /api/painel/s2210/status/:cpf`: consulta usada pelo painel, sem senha somente quando `PANEL_QUERY_AUTH_DISABLED=true`; mantenha a porta privada.
- `POST /api/painel/s2210/importar-xml`: upload sem senha somente na mesma condição de painel privado; campo multipart `files`, até 20 arquivos de 2 MiB.
- `POST /api/v1/s2210/webhook`: XML (`application/xml`) ou JSON (`application/json`), API key.
- `POST /api/v1/s2210/importar-xml`: upload multipart no campo `files` (API key ou JWT administrativo); máximo 20 arquivos, 2 MiB cada.
- `POST /api/v1/s2210/consultar-gov`: CPF em JSON (API key ou JWT administrativo); integração SOAP condicionada à configuração acima.
- `POST /api/login`: senha administrativa, retorna JWT.

Retorno de webhook S-2210 aceita `cdResposta` 201/202 e atualiza `nrRecibo` via UPSERT quando uma resposta posterior corresponder ao mesmo `Id`. XML de outros eventos é rejeitado. XML inválido para o XSD pode ser rejeitado pelo ambiente eSocial mesmo sendo parseável pela API.

## Comando de criação

Para recriar os arquivos-base desta aplicação em uma pasta vazia do Codespaces, execute `bash setup-project.sh`. O script contém os comandos `cat <<'EOF'` para gerar os arquivos.
EOF

echo "Projeto S-2210 criado. Copie .env.example para .env, configure os segredos e execute npm install."

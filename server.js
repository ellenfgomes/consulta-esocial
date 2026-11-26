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

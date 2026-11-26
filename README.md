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

O painel exibe literalmente `nrRecibo`, `cdResposta` e `descResposta` quando esses campos existem no retorno. Sem eles, informa “Sem retorno oficial”; um registro importado no SQLite não comprova por si só transmissão ou processamento pelo eSocial.

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

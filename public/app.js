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
  const hasOfficialReturn = cats.some((cat) => cat.nr_recibo || cat.cd_resposta || cat.desc_resposta);
  const statusLabel = hasOfficialReturn ? 'RETORNO OFICIAL DISPONÍVEL'
    : cats.length ? 'SEM RETORNO OFICIAL' : 'SEM REGISTRO LOCAL';
  target.replaceChildren();

  const card = document.createElement('article');
  card.className = 'result-card';
  const heading = document.createElement('div');
  heading.className = 'result-head';
  const title = document.createElement('strong');
  title.textContent = `${data.total_ocorrencias} ocorrência(s) de CAT`;
  const badge = document.createElement('span');
  badge.className = 'badge';
  badge.textContent = statusLabel;
  heading.append(title, badge);
  card.append(heading);

  if (!cats.length) {
    const empty = document.createElement('p');
    empty.className = 'muted';
    empty.textContent = 'Nenhum evento S-2210 localizado no banco local. Isso não confirma ausência no eSocial.';
    card.append(empty);
  }

  for (const cat of cats) {
    const details = document.createElement('div');
    details.className = 'result-grid';
    const noOfficialReturn = 'Sem retorno oficial';
    const values = [
      ['Id (evtCAT)', cat.id_evento || '—'],
      ['dtAcid', cat.data_acidente || '—'],
      ['tpAcid', cat.tp_acid || '—'],
      ['tpCat', cat.tp_cat || '—'],
      ['nrRecCatOrig', cat.nr_rec_cat_orig || '—'],
      ['nrRecibo', cat.nr_recibo || noOfficialReturn],
      ['cdResposta', cat.cd_resposta || noOfficialReturn],
      ['descResposta', cat.desc_resposta || noOfficialReturn]
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

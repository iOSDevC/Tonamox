// Tonamox browser page. Plain JS, no dependencies. Every server or model string reaches the DOM through
// textContent only; the token lives in sessionStorage and is sent only in the Authorization header.
'use strict';

(function () {
  const TOKEN_KEY = 'tonamox.token';
  const LANG_KEY = 'tonamox.lang';
  const REASON_KEY = 'tonamox.reason';
  const LENGTH_KEY = 'tonamox.length';
  // The page's reasoning choices, sent as reasoning_effort; the server turns each into its budget.
  const REASON_LEVELS = [
    { effort: 'none', key: 'chat.reason.none' },
    { effort: 'low', key: 'chat.reason.low' },
    { effort: 'medium', key: 'chat.reason.medium' },
    { effort: 'high', key: 'chat.reason.high' },
  ];
  // Sent as max_tokens; only those up to the hello's cap are offered.
  const LENGTH_CHOICES = [512, 1024, 2048, 4096];
  const RETRY_DELAYS = [1, 2, 4, 8, 15, 30];
  const LOOPBACK_HOSTS = ['127.0.0.1', 'localhost', '[::1]', '::1'];
  // Deep links that open the guide. The hash is only compared with these; closing the guide drops it.
  const GUIDE_HASHES = ['#guia', '#guide'];

  // BEGIN AnswerFormat. Pure text functions, no DOM: PageAnswerFormatTests evaluates this block alone and
  // checks it against BoxedAnswer in TonamoxCore on shared fixtures.
  const AnswerFormat = (function () {
    const BOX = '\\boxed{';
    const COMMANDS = ['\\boxed{', '\\text{', '\\textbf{', '\\mathrm{'];
    const WRAPPERS = [['$$', '$$'], ['\\(', '\\)'], ['\\[', '\\]'], ['$', '$']];

    // Lines with their terminators.
    function lines(text) {
      const result = [];
      let start = 0;
      for (let index = 0; index < text.length; index += 1) {
        if (text[index] === '\n') {
          result.push(text.slice(start, index + 1));
          start = index + 1;
        }
      }
      if (start < text.length) result.push(text.slice(start));
      return result;
    }

    // Up to three spaces, then three or more backticks or tildes; a backtick fence has no backtick after its marks.
    function fenceMark(line) {
      let indent = 0;
      while (indent < line.length && line[indent] === ' ') indent += 1;
      if (indent > 3 || indent >= line.length) return null;
      const mark = line[indent];
      if (mark !== '`' && mark !== '~') return null;
      let count = 0;
      while (line[indent + count] === mark) count += 1;
      if (count < 3) return null;
      if (mark === '`' && line.indexOf('`', indent + count) >= 0) return null;
      return { mark: mark, count: count };
    }

    function isBareFence(line) {
      return /^ *[`~]+[ \t\r\n]*$/.test(line);
    }

    function regions(text) {
      const result = [];
      let prose = '';
      let fence = null;
      let code = '';
      lines(text).forEach(function (line) {
        const mark = fenceMark(line);
        if (fence) {
          code += line;
          if (mark && mark.mark === fence.mark && mark.count >= fence.count && isBareFence(line)) {
            result.push({ code: true, text: code });
            code = '';
            fence = null;
          }
        } else if (mark) {
          inlineRegions(prose).forEach(function (region) { result.push(region); });
          prose = '';
          fence = mark;
          code = line;
        } else {
          prose += line;
        }
      });
      inlineRegions(prose).forEach(function (region) { result.push(region); });
      if (code) result.push({ code: true, text: code });
      return result;
    }

    function runLength(text, index) {
      let length = 0;
      while (text[index + length] === '`') length += 1;
      return length;
    }

    function closingRun(text, length, start) {
      let index = start;
      while (index < text.length) {
        if (text[index] !== '`') {
          index += 1;
          continue;
        }
        const run = runLength(text, index);
        if (run === length) return index;
        index += run;
      }
      return -1;
    }

    // Inline code: a run of backticks up to the next run of the same length; an unmatched run is prose.
    function inlineRegions(text) {
      const result = [];
      let prose = '';
      let index = 0;
      while (index < text.length) {
        if (text[index] !== '`') {
          prose += text[index];
          index += 1;
          continue;
        }
        const run = runLength(text, index);
        const close = closingRun(text, run, index + run);
        if (close >= 0) {
          if (prose) result.push({ code: false, text: prose });
          prose = '';
          result.push({ code: true, text: text.slice(index, close + run) });
          index = close + run;
        } else {
          prose += text.slice(index, index + run);
          index += run;
        }
      }
      if (prose) result.push({ code: false, text: prose });
      return result;
    }

    function closingBrace(text, start) {
      let depth = 0;
      let index = start;
      while (index < text.length) {
        const character = text[index];
        if (character === '\\') {
          index += 2;
          continue;
        }
        if (character === '{') {
          depth += 1;
        } else if (character === '}') {
          if (depth === 0) return index;
          depth -= 1;
        }
        index += 1;
      }
      return -1;
    }

    function box(text, index) {
      if (text.startsWith(BOX, index) === false) return null;
      const close = closingBrace(text, index + BOX.length);
      return close < 0 ? null : { end: close + 1, content: text.slice(index + BOX.length, close) };
    }

    function cleaned(content) {
      let output = '';
      let index = 0;
      while (index < content.length) {
        const command = COMMANDS.find(function (name) { return content.startsWith(name, index); });
        const close = command ? closingBrace(content, index + command.length) : -1;
        if (command && close >= 0) {
          output += cleaned(content.slice(index + command.length, close));
          index = close + 1;
        } else {
          output += content[index];
          index += 1;
        }
      }
      return output;
    }

    const GAP_SPACES = ' \t\n\r';
    // The characters of \s, listed so BoxedAnswer in Swift can trim the same ones.
    const TRIMMED = /^[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+|[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+$/g;
    const MARKS = '*_`';

    function skippingSpaces(text, start) {
      let index = start;
      while (index < text.length && GAP_SPACES.indexOf(text[index]) >= 0) index += 1;
      return index;
    }

    // Marks not already escaped get a backslash.
    function escaped(text) {
      let output = '';
      let index = 0;
      while (index < text.length) {
        if (text[index] === '\\' && index + 1 < text.length) {
          output += text.slice(index, index + 2);
          index += 2;
          continue;
        }
        if (MARKS.indexOf(text[index]) >= 0) output += '\\';
        output += text[index];
        index += 1;
      }
      return output;
    }

    // The same * or _ right before and right after the span.
    function isFramed(text, start, end) {
      if (start === 0 || end >= text.length) return false;
      const before = text[start - 1];
      return (before === '*' || before === '_') && text[end] === before;
    }

    function wrappedBox(text, index) {
      for (let position = 0; position < WRAPPERS.length; position += 1) {
        const wrapper = WRAPPERS[position];
        if (!text.startsWith(wrapper[0], index)) continue;
        const found = box(text, skippingSpaces(text, index + wrapper[0].length));
        if (!found) continue;
        const close = skippingSpaces(text, found.end);
        if (text.startsWith(wrapper[1], close)) return { box: found, end: close + wrapper[1].length };
      }
      return null;
    }

    function rendered(found, bold, framed) {
      const inner = cleaned(found.content).replace(TRIMMED, '');
      if (!inner) return '';
      if (!bold) return inner;
      const shown = escaped(inner);
      return framed ? shown : '**' + shown + '**';
    }

    function rewriteProse(text, bold) {
      let output = '';
      let index = 0;
      while (index < text.length) {
        const wrapped = wrappedBox(text, index);
        const found = wrapped ? null : box(text, index);
        if (wrapped) {
          output += rendered(wrapped.box, bold, isFramed(text, index, wrapped.end));
          index = wrapped.end;
        } else if (found) {
          output += rendered(found, bold, isFramed(text, index, found.end));
          index = found.end;
        } else {
          output += text[index];
          index += 1;
        }
      }
      return output;
    }

    function rewrite(text, bold) {
      if (text.indexOf(BOX) < 0) return text;
      return regions(text).map(function (region) {
        return region.code ? region.text : rewriteProse(region.text, bold);
      }).join('');
    }

    // Markdown subset: paragraphs, fenced code, bullet and numbered lists. Plain objects only.
    function blocks(text) {
      const result = [];
      let paragraph = null;
      let list = null;
      let fence = null;
      const close = function () {
        if (paragraph !== null) result.push({ type: 'paragraph', inlines: inlines(paragraph) });
        if (list) result.push({ type: 'list', ordered: list.ordered, start: list.start, items: list.items.map(inlines) });
        paragraph = null;
        list = null;
      };
      lines(text).forEach(function (raw) {
        const line = raw.replace(/\r?\n$/, '');
        if (fence) {
          const mark = fenceMark(line);
          if (mark && mark.mark === fence.mark && mark.count >= fence.count && isBareFence(line)) {
            result.push({ type: 'code', language: fence.language, text: fence.lines.join('\n') });
            fence = null;
          } else {
            fence.lines.push(line);
          }
          return;
        }
        const mark = fenceMark(line);
        if (mark) {
          close();
          const info = line.trim().slice(mark.count).trim().split(/\s+/)[0] || '';
          fence = { mark: mark.mark, count: mark.count, language: info, lines: [] };
          return;
        }
        if (!line.trim()) {
          close();
          return;
        }
        const bullet = /^ {0,3}[-*+][ \t]+(.*)$/.exec(line);
        const numbered = /^ {0,3}(\d{1,9})[.)][ \t]+(.*)$/.exec(line);
        if (bullet || numbered) {
          const ordered = Boolean(numbered);
          if (!list || list.ordered !== ordered) {
            close();
            list = { ordered: ordered, start: ordered ? Number(numbered[1]) : 1, items: [] };
          }
          list.items.push(ordered ? numbered[2] : bullet[1]);
          return;
        }
        if (list && /^[ \t]+\S/.test(line)) {
          list.items[list.items.length - 1] += ' ' + line.trim();
          return;
        }
        if (list) close();
        paragraph = paragraph === null ? line : paragraph + '\n' + line;
      });
      if (fence) result.push({ type: 'code', language: fence.language, text: fence.lines.join('\n') });
      close();
      return result;
    }

    function pushText(nodes, text) {
      if (!text) return;
      const last = nodes[nodes.length - 1];
      if (last && last.type === 'text') last.text += text;
      else nodes.push({ type: 'text', text: text });
    }

    // Closers tried per opener: a long reply full of stray markers would otherwise cost quadratic time per draw.
    const EMPHASIS_TRIES = 64;

    // Emphasis needs text right inside its markers; "_" also needs no letter or digit outside them.
    function emphasis(text, index, marker) {
      const width = marker.length;
      if (!text.startsWith(marker, index)) return null;
      const first = text[index + width];
      if (first === undefined || first === ' ' || first === marker[0]) return null;
      if (marker[0] === '_' && index > 0 && /[A-Za-z0-9]/.test(text[index - 1])) return null;
      let close = text.indexOf(marker, index + width + 1);
      for (let tries = 0; close >= 0 && tries < EMPHASIS_TRIES; tries += 1) {
        const before = text[close - 1];
        const after = text[close + width];
        const boundary = marker[0] !== '_' || after === undefined || !/[A-Za-z0-9]/.test(after);
        if (before !== ' ' && after !== marker[0] && boundary) return close;
        close = text.indexOf(marker, close + 1);
      }
      return null;
    }

    function inlines(text) {
      const nodes = [];
      let index = 0;
      while (index < text.length) {
        const character = text[index];
        if (character === '\\' && index + 1 < text.length && /[\\`*_{}\[\]()#+\-.!>~|]/.test(text[index + 1])) {
          pushText(nodes, text[index + 1]);
          index += 2;
          continue;
        }
        if (character === '`') {
          const run = runLength(text, index);
          const close = closingRun(text, run, index + run);
          if (close >= 0) {
            nodes.push({ type: 'code', text: text.slice(index + run, close).replace(/^ (.*) $/, '$1') });
            index = close + run;
          } else {
            pushText(nodes, text.slice(index, index + run));
            index += run;
          }
          continue;
        }
        if (character === '[') {
          const link = /^\[([^\[\]\n]+)\]\(([^()\s]*)\)/.exec(text.slice(index));
          if (link) {
            nodes.push({ type: 'link', label: link[1], url: link[2] });
            index += link[0].length;
            continue;
          }
        }
        if (character === '*' || character === '_') {
          const strongMarker = character + character;
          const strongEnd = emphasis(text, index, strongMarker);
          if (strongEnd !== null) {
            nodes.push({ type: 'strong', children: inlines(text.slice(index + 2, strongEnd)) });
            index = strongEnd + 2;
            continue;
          }
          const emEnd = emphasis(text, index, character);
          if (emEnd !== null) {
            nodes.push({ type: 'em', children: inlines(text.slice(index + 1, emEnd)) });
            index = emEnd + 1;
            continue;
          }
        }
        pushText(nodes, character);
        index += 1;
      }
      return nodes;
    }

    function linkText(node) {
      return node.url && node.url !== node.label ? node.label + ' (' + node.url + ')' : node.label;
    }

    function inlineText(nodes) {
      return nodes.map(function (node) {
        if (node.type === 'strong' || node.type === 'em') return inlineText(node.children);
        if (node.type === 'link') return linkText(node);
        return node.text;
      }).join('');
    }

    // The answer as the page shows it, in plain text: what the Copy button copies.
    function shownText(text) {
      return blocks(rewrite(text, true)).map(function (block) {
        if (block.type === 'code') return block.text;
        if (block.type === 'list') {
          return block.items.map(function (item, position) {
            return (block.ordered ? String(block.start + position) + '. ' : '- ') + inlineText(item);
          }).join('\n');
        }
        return inlineText(block.inlines);
      }).join('\n\n');
    }

    return {
      display: function (text) { return rewrite(text, true); },
      plain: function (text) { return rewrite(text, false); },
      blocks: blocks,
      inlines: inlines,
      linkText: linkText,
      shownText: shownText,
    };
  })();
  // END AnswerFormat

  // One entry per key, es and en on their own lines: BrowserPageTests parses this block.
  const STRINGS = {
    'doc.title': {
      es: 'Tonamox · servidor local',
      en: 'Tonamox · local server',
    },
    'lang.group': {
      es: 'Idioma',
      en: 'Language',
    },
    'lang.changed': {
      es: 'Idioma: español',
      en: 'Language: English',
    },
    'top.logout': {
      es: 'Cerrar sesión',
      en: 'Sign out',
    },
    'top.guide': {
      es: 'Guía',
      en: 'Guide',
    },
    'top.model': {
      es: 'Modelo: {model}',
      en: 'Model: {model}',
    },
    'banner.unencrypted.title': {
      es: 'Conexión sin cifrar.',
      en: 'Unencrypted connection.',
    },
    'banner.unencrypted.body': {
      es: 'Cualquier dispositivo de esta red puede leer lo que escribes, las respuestas y el token de esta sesión. Para algo privado usa el cable USB o este mismo ordenador (127.0.0.1).',
      en: 'Anyone on this network can read what you type, the replies and this session’s token. For anything private, use the USB cable or this same computer (127.0.0.1).',
    },
    'loading.text': {
      es: 'Conectando con el servidor…',
      en: 'Connecting to the server…',
    },
    'footer.text': {
      es: 'Servidor local de Tonamox. La página no carga nada de fuera de este servidor y guarda el token y el idioma elegido solo en esta pestaña.',
      en: 'Tonamox local server. This page loads nothing from outside this server and keeps the token and the chosen language only in this tab.',
    },
    'device.app': {
      es: 'el teléfono',
      en: 'the phone',
    },
    'device.cli': {
      es: 'este ordenador',
      en: 'this computer',
    },
    'device.any': {
      es: 'el dispositivo que sirve esta página',
      en: 'the device serving this page',
    },
    'pair.title': {
      es: 'Emparejar este navegador',
      en: 'Pair this browser',
    },
    'pair.step.open': {
      es: 'Abre la ventana de emparejamiento donde corre el servidor: en la app del teléfono, o pulsando Enter en el terminal de «tonamox serve --browser» (al arrancar ya abre una). Se cierra sola al cabo de unos minutos y admite un solo navegador.',
      en: 'Open the pairing window where the server runs: in the phone app, or by pressing Enter in the terminal running “tonamox serve --browser” (it opens one at startup). It closes by itself after a few minutes and accepts one browser.',
    },
    'pair.step.request': {
      es: 'Pulsa «Solicitar código». Aparecerá un código de 8 caracteres en la app o en ese terminal; la app muestra también la dirección de este ordenador.',
      en: 'Press “Request code”. An 8-character code appears in the app or in that terminal; the app also shows this computer’s address.',
    },
    'pair.step.type': {
      es: 'Escribe aquí ese código. El código nunca se envía a esta página: solo lo ves allí.',
      en: 'Type that code here. The code is never sent to this page: you only see it there.',
    },
    'pair.name.label': {
      es: 'Nombre de este ordenador (opcional)',
      en: 'Name for this computer (optional)',
    },
    'pair.request': {
      es: 'Solicitar código',
      en: 'Request code',
    },
    'pair.code.label': {
      es: 'Código que muestra la app o el terminal',
      en: 'Code shown in the app or the terminal',
    },
    'pair.claim': {
      es: 'Emparejar',
      en: 'Pair',
    },
    'pair.restart': {
      es: 'Pedir otro código',
      en: 'Get a new code',
    },
    'pair.requesting': {
      es: 'Solicitando…',
      en: 'Requesting…',
    },
    'pair.unreachable': {
      es: 'No se pudo contactar con el servidor.',
      en: 'Could not reach the server.',
    },
    'pair.typeCode.one': {
      es: 'Escribe el código que se muestra donde corre el servidor. Tienes {attempts} intento.',
      en: 'Type the code shown where the server runs. You have {attempts} attempt.',
    },
    'pair.typeCode.other': {
      es: 'Escribe el código que se muestra donde corre el servidor. Tienes {attempts} intentos.',
      en: 'Type the code shown where the server runs. You have {attempts} attempts.',
    },
    'pair.sessionEnded': {
      es: 'La sesión terminó o caducó. Vuelve a emparejar este navegador.',
      en: 'The session ended or expired. Pair this browser again.',
    },
    'pair.signedOut': {
      es: 'Sesión cerrada.',
      en: 'Signed out.',
    },
    'session.until': {
      es: 'Sesión válida hasta las {time}',
      en: 'Session valid until {time}',
    },
    'retry.app': {
      es: 'El teléfono no responde (¿la app está en segundo plano o la pantalla bloqueada?). Reintentando en {seconds} s…',
      en: 'The phone is not answering (is the app in the background or the screen locked?). Retrying in {seconds} s…',
    },
    'retry.cli': {
      es: 'El servidor no responde (¿se detuvo «tonamox serve»?). Reintentando en {seconds} s…',
      en: 'The server is not answering (did “tonamox serve” stop?). Retrying in {seconds} s…',
    },
    'retry.any': {
      es: 'El servidor no responde (¿la app está en segundo plano, la pantalla bloqueada o se detuvo «tonamox serve»?). Reintentando en {seconds} s…',
      en: 'The server is not answering (is the app in the background, the screen locked, or did “tonamox serve” stop?). Retrying in {seconds} s…',
    },
    'net.where': {
      es: '{Device} escucha en {network}: el tráfico es observable en esa red.',
      en: '{Device} listens on {network}: traffic is observable on that network.',
    },
    'net.wifi': {
      es: 'la Wi-Fi',
      en: 'Wi-Fi',
    },
    'net.personal_hotspot': {
      es: 'el punto de acceso personal',
      en: 'the Personal Hotspot',
    },
    'net.wired': {
      es: 'la red por cable',
      en: 'the wired network',
    },
    'net.named': {
      es: 'la interfaz {name}',
      en: 'interface {name}',
    },
    'net.unknown': {
      es: 'una red',
      en: 'a network',
    },
    'chat.title': {
      es: 'Chat',
      en: 'Chat',
    },
    'chat.model.label': {
      es: 'Modelo',
      en: 'Model',
    },
    'chat.clear': {
      es: 'Nueva conversación',
      en: 'New conversation',
    },
    'chat.empty': {
      es: 'La conversación vive solo en esta pestaña: el servidor no la guarda.',
      en: 'The conversation lives only in this tab: the server does not keep it.',
    },
    'chat.prompt.label': {
      es: 'Mensaje',
      en: 'Message',
    },
    'chat.prompt.placeholder': {
      es: 'Escribe un mensaje. Enter envía; Mayús+Enter añade una línea.',
      en: 'Type a message. Enter sends; Shift+Enter adds a line.',
    },
    'chat.send': {
      es: 'Enviar',
      en: 'Send',
    },
    'chat.stop': {
      es: 'Detener',
      en: 'Stop',
    },
    'chat.role.user': {
      es: 'Tú',
      en: 'You',
    },
    'chat.role.assistant': {
      es: 'Modelo',
      en: 'Model',
    },
    'chat.stopped': {
      es: 'Respuesta detenida.',
      en: 'Reply stopped.',
    },
    'chat.stoppedNote': {
      es: '(detenida)',
      en: '(stopped)',
    },
    'chat.lost': {
      es: 'Se perdió la conexión con {device}.',
      en: 'Lost the connection to {device}.',
    },
    'chat.noModels': {
      es: 'Este servidor no ofrece ningún modelo ahora mismo.',
      en: 'This server offers no model right now.',
    },
    'chat.tooManyMessages': {
      es: 'La conversación alcanzó el límite del servidor (mensajes por conversación: {messages}). Empieza una nueva.',
      en: 'The conversation reached the server’s limit (messages per conversation: {messages}). Start a new one.',
    },
    'chat.guideHint': {
      es: 'Abre la Guía, arriba, para ver qué ofrece este servidor y cómo conectar un cliente de API.',
      en: 'Open the Guide, at the top, to see what this server offers and how to connect an API client.',
    },
    'chat.reasoning.live': {
      es: 'Pensando…',
      en: 'Thinking…',
    },
    'chat.reasoning.brief': {
      es: 'Pensó un momento',
      en: 'Thought for a moment',
    },
    'chat.reasoning.done.one': {
      es: 'Pensó durante {seconds} segundo',
      en: 'Thought for {seconds} second',
    },
    'chat.reasoning.done.other': {
      es: 'Pensó durante {seconds} segundos',
      en: 'Thought for {seconds} seconds',
    },
    'chat.reasoning.unfinished': {
      es: 'El modelo razonó pero no dio ninguna respuesta.',
      en: 'The model reasoned but gave no answer.',
    },
    'chat.contentFilter': {
      es: 'Las reglas de seguridad del modelo cortaron esta respuesta. Prueba a reformular la pregunta.',
      en: 'The model’s safety rules cut this reply short. Try rephrasing the question.',
    },
    'chat.reasoning.interrupted': {
      es: 'Razonamiento interrumpido',
      en: 'Reasoning interrupted',
    },
    'chat.reasoning.cut.brief': {
      es: 'Razonamiento recortado',
      en: 'Reasoning cut short',
    },
    'chat.reasoning.cut.one': {
      es: 'Razonamiento recortado tras {seconds} segundo',
      en: 'Reasoning cut after {seconds} second',
    },
    'chat.reasoning.cut.other': {
      es: 'Razonamiento recortado tras {seconds} segundos',
      en: 'Reasoning cut after {seconds} seconds',
    },
    'chat.reason': {
      es: 'Razonar',
      en: 'Reasoning',
    },
    'chat.reason.none': {
      es: 'Razonar: no',
      en: 'Reasoning: off',
    },
    'chat.reason.low': {
      es: 'Razonar: bajo',
      en: 'Reasoning: low',
    },
    'chat.reason.medium': {
      es: 'Razonar: medio',
      en: 'Reasoning: medium',
    },
    'chat.reason.high': {
      es: 'Razonar: alto',
      en: 'Reasoning: high',
    },
    'chat.length': {
      es: 'Longitud',
      en: 'Length',
    },
    'chat.length.option': {
      es: 'Longitud: {tokens} tokens',
      en: 'Length: {tokens} tokens',
    },
    'chat.copy': {
      es: 'Copiar',
      en: 'Copy',
    },
    'chat.copyFailed': {
      es: 'No se pudo copiar',
      en: 'Could not copy',
    },
    'chat.copied': {
      es: 'Copiada',
      en: 'Copied',
    },
    'dest.short.on_device': {
      es: 'en {device}',
      en: 'on {device}',
    },
    'dest.short.local_network': {
      es: 'sale a la red local',
      en: 'goes to the local network',
    },
    'dest.short.cloud': {
      es: 'sale a la nube',
      en: 'goes to the cloud',
    },
    'dest.short.unknown': {
      es: 'destino desconocido',
      en: 'unknown destination',
    },
    'dest.long.on_device': {
      es: 'Se ejecuta en {device}: el texto no sale de ahí.',
      en: 'Runs on {device}: the text does not leave it.',
    },
    'dest.long.local_network': {
      es: '{Device} envía el texto a {host} en la red local. Pide consentimiento en cada solicitud y muestra exactamente lo que se envía.',
      en: '{Device} sends the text to {host} on the local network. It asks for consent on every request and shows exactly what is sent.',
    },
    'dest.long.cloud': {
      es: '{Device} envía el texto a {provider}, en la nube. Pide consentimiento en cada solicitud y muestra exactamente lo que se envía.',
      en: '{Device} sends the text to {provider}, in the cloud. It asks for consent on every request and shows exactly what is sent.',
    },
    'dest.long.unknown': {
      es: 'Destino no declarado: trátalo como si saliera del dispositivo.',
      en: 'Undeclared destination: treat it as if it leaves the device.',
    },
    'dest.retention': {
      es: 'Nota del proveedor, tal como la escribió quien configuró el servidor:',
      en: 'Provider note, as written by whoever set up the server:',
    },
    'err.pairing_closed': {
      es: 'La ventana de emparejamiento está cerrada. Ábrela donde corre el servidor y vuelve a pedir el código.',
      en: 'The pairing window is closed. Open it where the server runs and request the code again.',
    },
    'err.pairing_busy': {
      es: 'Ya hay otra solicitud de emparejamiento pendiente. Espera a que caduque o deniégala en la app.',
      en: 'Another pairing request is pending. Wait for it to expire or deny it in the app.',
    },
    'err.pairing_expired': {
      es: 'La solicitud caducó. Pide otro código.',
      en: 'The request expired. Get a new code.',
    },
    'err.invalid_pairing_code': {
      es: 'El código no coincide. Revisa el que se muestra donde corre el servidor.',
      en: 'The code does not match. Check the one shown where the server runs.',
    },
    'err.not_found': {
      es: 'La solicitud ya no existe (código incorrecto demasiadas veces, denegada o caducada). Pide otro código.',
      en: 'The request no longer exists (too many wrong codes, denied or expired). Get a new code.',
    },
    'err.rate_limited': {
      es: 'Demasiadas solicitudes seguidas. Espera un minuto.',
      en: 'Too many requests in a row. Wait a minute.',
    },
    'err.server_busy': {
      es: 'El modelo está ocupado con otra respuesta. Inténtalo en unos segundos.',
      en: 'The model is busy with another reply. Try again in a few seconds.',
    },
    'err.app_backgrounded': {
      es: 'La app del teléfono pasó a segundo plano y la respuesta se cortó.',
      en: 'The phone app went to the background and the reply was cut off.',
    },
    'err.model_unavailable': {
      es: 'El modelo no está disponible ahora mismo.',
      en: 'The model is not available right now.',
    },
    'err.model_changed': {
      es: 'Este modelo se retiró del servidor mientras respondía.',
      en: 'This model was removed from the server while it was replying.',
    },
    'err.model_not_found': {
      es: 'El servidor ya no ofrece este modelo.',
      en: 'The server no longer offers this model.',
    },
    'err.consent_declined': {
      es: 'No se autorizó enviar esta solicitud fuera del dispositivo.',
      en: 'Sending this request off the device was not approved.',
    },
    'err.consent_timeout': {
      es: 'Nadie aprobó el envío a tiempo en {device}.',
      en: 'Nobody approved the send on {device} in time.',
    },
    'err.escalation_off': {
      es: 'El envío fuera del dispositivo está desactivado en este servidor.',
      en: 'Sending off the device is turned off on this server.',
    },
    'err.egress_not_allowed': {
      es: 'Este servidor no permite enviar a la nube.',
      en: 'This server does not allow sending to the cloud.',
    },
    'err.context_length_exceeded': {
      es: 'La conversación es demasiado larga para este modelo. Empieza una nueva.',
      en: 'The conversation is too long for this model. Start a new one.',
    },
    'err.unsupported_language': {
      es: 'El modelo no admite el idioma de esta solicitud.',
      en: 'The model does not support the language of this request.',
    },
    'err.request_too_large': {
      es: 'El mensaje o la conversación supera el tamaño que admite el servidor.',
      en: 'The message or the conversation is larger than the server accepts.',
    },
    'err.invalid_messages': {
      es: 'El mensaje o la conversación supera los límites del servidor (mensajes por conversación: {messages}; caracteres por mensaje: {characters}).',
      en: 'The message or the conversation is outside the server’s limits (messages per conversation: {messages}; characters per message: {characters}).',
    },
    'err.unsupported_parameter': {
      es: 'El servidor no admite uno de los parámetros de la solicitud.',
      en: 'The server does not support one of the request’s parameters.',
    },
    'err.bad_request': {
      es: 'El servidor no entendió la solicitud.',
      en: 'The server could not understand the request.',
    },
    'err.insufficient_scope': {
      es: 'Esta sesión no tiene permiso para hacer eso.',
      en: 'This session is not allowed to do that.',
    },
    'err.origin_not_allowed': {
      es: 'El servidor rechazó el origen de esta página.',
      en: 'The server refused this page’s origin.',
    },
    'err.cross_site': {
      es: 'El servidor rechazó una solicitud que venía de otro sitio.',
      en: 'The server refused a request that came from another site.',
    },
    'err.misdirected_request': {
      es: 'El servidor no responde a este nombre de host (421). Añádelo a los nombres de host permitidos.',
      en: 'The server does not answer for this host name (421). Add it to the allowed host names.',
    },
    'err.expired_api_key': {
      es: 'La sesión caducó.',
      en: 'The session expired.',
    },
    'err.invalid_api_key': {
      es: 'El servidor no reconoce esta sesión.',
      en: 'The server does not recognize this session.',
    },
    'err.internal': {
      es: 'Error interno del servidor.',
      en: 'Internal server error.',
    },
    'err.incomplete': {
      es: 'La respuesta terminó sin completarse.',
      en: 'The reply ended before it was complete.',
    },
    'err.server': {
      es: 'El servidor respondió: {detail}',
      en: 'The server replied: {detail}',
    },
    'err.status': {
      es: 'El servidor respondió con el estado {status}.',
      en: 'The server replied with status {status}.',
    },
    'guide.title': {
      es: 'Guía de este servidor',
      en: 'Guide to this server',
    },
    'guide.intro.app': {
      es: 'Generada con lo que este servidor ofrece ahora mismo. Desde el navegador no se cambia ningún ajuste: todo se configura en el teléfono.',
      en: 'Built from what this server offers right now. No setting can be changed from the browser: everything is configured on the phone.',
    },
    'guide.intro.cli': {
      es: 'Generada con lo que este servidor ofrece ahora mismo. Desde el navegador no se cambia ningún ajuste: todo se fija al arrancar «tonamox serve».',
      en: 'Built from what this server offers right now. No setting can be changed from the browser: everything is set when “tonamox serve” starts.',
    },
    'guide.copy': {
      es: 'Copiar',
      en: 'Copy',
    },
    'guide.copied': {
      es: 'Copiado',
      en: 'Copied',
    },
    'guide.close': {
      es: 'Cerrar',
      en: 'Close',
    },
    'guide.where.title': {
      es: 'Dónde escucha',
      en: 'Where it listens',
    },
    'guide.where.cliLoopback': {
      es: 'Solo en este ordenador (127.0.0.1, puerto {port}), servido por el comando «tonamox serve». Otros ordenadores no llegan a él.',
      en: 'Only on this computer (127.0.0.1, port {port}), served by the “tonamox serve” command. Other computers cannot reach it.',
    },
    'guide.where.appLoopback': {
      es: 'Solo en el propio teléfono (127.0.0.1, puerto {port}). Desde un ordenador se llega por el cable USB con un reenviador que escuche en 127.0.0.1 de ese ordenador, por ejemplo:',
      en: 'Only on the phone itself (127.0.0.1, port {port}). A computer reaches it over the USB cable through a forwarder that listens on that computer’s 127.0.0.1, for example:',
    },
    'guide.where.forwarderPort': {
      es: 'Si el reenviador usa otro puerto local, añade «127.0.0.1:<puerto>» a los nombres de host permitidos en el teléfono; si no, el servidor responde 421.',
      en: 'If the forwarder uses another local port, add “127.0.0.1:<port>” to the allowed host names on the phone; otherwise the server answers 421.',
    },
    'guide.where.interface': {
      es: 'En la interfaz {name} del teléfono ({address}, puerto {port}). Sin cifrar: todo lo que pasa por ella, credenciales incluidas, se puede leer y modificar en esa red.',
      en: 'On the phone’s {name} interface ({address}, port {port}). Unencrypted: everything that crosses it, credentials included, can be read and changed on that network.',
    },
    'guide.where.peerLock': {
      es: 'Solo admite al primer ordenador que se emparejó o usó una clave; para otro, permítelo desde el teléfono.',
      en: 'Only the first computer that paired or used a key gets in; to let another one in, allow it from the phone.',
    },
    'guide.where.idle.one': {
      es: 'Se detiene solo tras {minutes} minuto sin solicitudes.',
      en: 'It stops by itself after {minutes} minute without requests.',
    },
    'guide.where.idle.other': {
      es: 'Se detiene solo tras {minutes} minutos sin solicitudes.',
      en: 'It stops by itself after {minutes} minutes without requests.',
    },
    'guide.where.foreground': {
      es: 'Sirve solo con la app en primer plano: si pasa a segundo plano, las conexiones se cierran y esta página reintenta sola.',
      en: 'It serves only while the app is in the foreground: in the background, connections close and this page retries by itself.',
    },
    'guide.where.cliRunning': {
      es: 'Sirve mientras el comando siga en marcha; Ctrl-C en su terminal lo detiene y cierra esta sesión.',
      en: 'It serves while the command keeps running; Ctrl-C in its terminal stops it and ends this session.',
    },
    'guide.models.title': {
      es: 'Modelos que sirve',
      en: 'Models it serves',
    },
    'guide.models.context': {
      es: ' · contexto de {tokens} tokens',
      en: ' · {tokens}-token context',
    },
    'guide.models.none': {
      es: 'Ninguno ahora mismo.',
      en: 'None right now.',
    },
    'guide.limits.title': {
      es: 'Límites',
      en: 'Limits',
    },
    'guide.limits.queue': {
      es: 'Una respuesta a la vez; hasta {seconds} s de espera en cola, luego error 429.',
      en: 'One reply at a time; up to {seconds} s waiting in the queue, then error 429.',
    },
    'guide.limits.tokens': {
      es: 'Tokens por respuesta: {standard} por defecto, {cap} como máximo (max_tokens o max_completion_tokens).',
      en: 'Tokens per reply: {standard} by default, {cap} at most (max_tokens or max_completion_tokens).',
    },
    'guide.limits.rate': {
      es: 'Solicitudes de chat por minuto y cliente: {count}.',
      en: 'Chat requests per minute per client: {count}.',
    },
    'guide.limits.size': {
      es: 'Mensajes por conversación: hasta {messages}; caracteres por mensaje: hasta {characters}; cuerpo: hasta {body}.',
      en: 'Messages per conversation: up to {messages}; characters per message: up to {characters}; body: up to {body}.',
    },
    'guide.limits.session': {
      es: 'Sesión del navegador: {idle} min sin uso o {hours} h en total.',
      en: 'Browser session: {idle} min idle or {hours} h in total.',
    },
    'guide.limits.unsupported': {
      es: 'Sin herramientas (tools), response_format, n > 1 ni stop: el servidor responde 400 si se piden.',
      en: 'No tools, response_format, n > 1 or stop: the server answers 400 if they are requested.',
    },
    'guide.api.title': {
      es: 'Conectar un cliente de API',
      en: 'Connect an API client',
    },
    'guide.api.cliKey': {
      es: '«tonamox serve» no muestra la clave: escribió la línea de cabecera en un archivo que solo tú puedes leer (0600) e imprimió su ruta al arrancar. La clave vale mientras el comando siga en marcha. Usa esa ruta en lugar de {file}:',
      en: '“tonamox serve” does not show the key: it wrote the header line to a file only you can read (0600) and printed its path at startup. The key is valid while the command keeps running. Use that path instead of {file}:',
    },
    'guide.api.appKey.one': {
      es: 'Las claves se crean en el teléfono, se muestran una sola vez y caducan a {days} día por defecto (se pueden revocar allí). Guarda la línea de cabecera que muestra el teléfono en un archivo que solo tú puedas leer:',
      en: 'Keys are created on the phone, shown once, and expire after {days} day by default (you can revoke them there). Save the header line the phone shows to a file only you can read:',
    },
    'guide.api.appKey.other': {
      es: 'Las claves se crean en el teléfono, se muestran una sola vez y caducan a los {days} días por defecto (se pueden revocar allí). Guarda la línea de cabecera que muestra el teléfono en un archivo que solo tú puedas leer:',
      en: 'Keys are created on the phone, shown once, and expire after {days} days by default (you can revoke them there). Save the header line the phone shows to a file only you can read:',
    },
    'guide.api.paste': {
      es: 'Pega «Authorization: Bearer tnx_…», pulsa Enter y luego Ctrl-D. Después:',
      en: 'Paste “Authorization: Bearer tnx_…”, press Enter, then Ctrl-D. Then:',
    },
    'guide.api.compatible': {
      es: 'Para un cliente compatible con OpenAI (editores, SDK): URL base y clave:',
      en: 'For an OpenAI-compatible client (editors, SDKs): base URL and key:',
    },
    'guide.api.noArgv': {
      es: 'No pongas la clave en la línea de comandos ni en una variable del shell: otros procesos del ordenador pueden leerla (ps).',
      en: 'Do not put the key on the command line or in a shell variable: other processes on the computer can read it (ps).',
    },
    'guide.ph.file': {
      es: '<archivo>',
      en: '<file>',
    },
    'guide.ph.model': {
      es: '<modelo>',
      en: '<model>',
    },
    'guide.ph.command': {
      es: '<comando>',
      en: '<command>',
    },
    'guide.example.greeting': {
      es: 'Hola',
      en: 'Hello',
    },
    'guide.ingest.title': {
      es: 'Enviar la salida de un comando',
      en: 'Send a command’s output',
    },
    'guide.ingest.ticket': {
      es: '{Device} crea un ticket de un solo uso ({minutes} min, hasta {standard} por defecto y {max} como máximo) y escribe una línea como esta:',
      en: '{Device} creates a single-use ticket ({minutes} min, up to {standard} by default and {max} at most) and types a line like this:',
    },
    'guide.ingest.untrusted': {
      es: 'La salida llega a {device} marcada como datos no confiables. Un segundo envío con el mismo ticket recibe 409 y se avisa. Envíos por minuto: {count} como máximo.',
      en: 'The output reaches {device} marked as untrusted data. A second upload with the same ticket gets 409 and you are warned. Uploads per minute: at most {count}.',
    },
    'guide.scripts.title': {
      es: 'Scripts auxiliares',
      en: 'Helper scripts',
    },
    'guide.scripts.compare': {
      es: 'Compara siempre el hash con el que muestra {device}: esta página viaja por la misma conexión que el script.',
      en: 'Always compare the hash with the one {device} shows: this page travels over the same connection as the script.',
    },
    'guide.scripts.macos': {
      es: 'En macOS:',
      en: 'On macOS:',
    },
    'guide.scripts.linux': {
      es: 'En Linux:',
      en: 'On Linux:',
    },
    'guide.cli.title': {
      es: 'Qué se configura en el comando «tonamox serve»',
      en: 'What the “tonamox serve” command sets',
    },
    'guide.cli.model': {
      es: 'El modelo (--model) y el puerto (--port) al arrancarla.',
      en: 'The model (--model) and the port (--port), when you start it.',
    },
    'guide.cli.browser': {
      es: 'La página y el emparejamiento (--browser): el código aparece en su terminal y Enter abre otra ventana.',
      en: 'The page and pairing (--browser): the code appears in its terminal and Enter opens another window.',
    },
    'guide.cli.stop': {
      es: 'Ctrl-C detiene el servidor y anula la clave y las sesiones.',
      en: 'Ctrl-C stops the server and voids the key and the sessions.',
    },
    'guide.phone.title': {
      es: 'Qué se configura en el teléfono',
      en: 'What is set on the phone',
    },
    'guide.phone.start': {
      es: 'Arrancar y detener el servidor, y elegir dónde escucha.',
      en: 'Starting and stopping the server, and choosing where it listens.',
    },
    'guide.phone.pairing': {
      es: 'Abrir la ventana de emparejamiento, ver el código y denegar solicitudes.',
      en: 'Opening the pairing window, seeing the code and denying requests.',
    },
    'guide.phone.keys': {
      es: 'Crear y revocar claves de API; cerrar las sesiones de navegador.',
      en: 'Creating and revoking API keys; ending browser sessions.',
    },
    'guide.phone.models': {
      es: 'Elegir qué modelos se sirven y aprobar cada envío de los que salen del dispositivo.',
      en: 'Choosing which models are served and approving each send that leaves the device.',
    },
    'guide.phone.ingestOn': {
      es: 'Crear tickets de ingesta para cada comando.',
      en: 'Creating ingest tickets for each command.',
    },
    'guide.phone.ingestOff': {
      es: 'La ingesta de salida está desactivada.',
      en: 'Output ingest is turned off.',
    },
    'guide.phone.scriptsOn': {
      es: 'Ver el hash de cada script auxiliar.',
      en: 'Seeing the hash of each helper script.',
    },
    'guide.phone.scriptsOff': {
      es: 'Los scripts auxiliares están desactivados.',
      en: 'Helper scripts are turned off.',
    },
    'guide.phone.hosts': {
      es: 'Añadir nombres de host para un reenviador USB en otro puerto.',
      en: 'Adding host names for a USB forwarder on another port.',
    },
    'guide.session.title': {
      es: 'Esta sesión',
      en: 'This session',
    },
    'guide.session.who': {
      es: 'Nombre: {label}. Permisos: {scopes}.',
      en: 'Name: {label}. Permissions: {scopes}.',
    },
    'guide.session.unnamed': {
      es: 'este navegador (sin nombre)',
      en: 'this browser (no name given)',
    },
    'scope.chat': {
      es: 'chat',
      en: 'chat',
    },
    'scope.models': {
      es: 'lista de modelos',
      en: 'model list',
    },
    'scope.session': {
      es: 'sesión',
      en: 'session',
    },
    'guide.session.expiry': {
      es: 'Caduca a las {time} o tras {minutes} min sin uso.',
      en: 'Expires at {time} or after {minutes} min idle.',
    },
    'guide.session.tab': {
      es: 'El token se guarda solo en esta pestaña; al cerrarla se pierde.',
      en: 'The token is kept only in this tab; closing the tab discards it.',
    },
  };

  const LANGUAGES = ['es', 'en'];
  // Created once per language; ports and codes are never passed through these.
  const TIME_FORMATS = {
    es: new Intl.DateTimeFormat('es', { hour: '2-digit', minute: '2-digit' }),
    en: new Intl.DateTimeFormat('en', { hour: '2-digit', minute: '2-digit' }),
  };
  const NUMBER_FORMATS = {
    es: new Intl.NumberFormat('es', { maximumFractionDigits: 2 }),
    en: new Intl.NumberFormat('en', { maximumFractionDigits: 2 }),
  };
  const PLURAL_RULES = {
    es: new Intl.PluralRules('es'),
    en: new Intl.PluralRules('en'),
  };
  const DEVICE_KEYS = { app: 'device.app', cli: 'device.cli', any: 'device.any' };
  const RETRY_KEYS = { app: 'retry.app', cli: 'retry.cli', any: 'retry.any' };
  const NETWORK_KEYS = { wifi: 'net.wifi', personal_hotspot: 'net.personal_hotspot', wired: 'net.wired' };
  const SCOPE_KEYS = { chat: 'scope.chat', models: 'scope.models', session: 'scope.session' };
  const ERROR_KEYS = {
    invalid_messages: 'err.invalid_messages',
    unsupported_parameter: 'err.unsupported_parameter',
    invalid_json: 'err.bad_request',
    invalid_reasoning_effort: 'err.bad_request',
    conflicting_reasoning: 'err.bad_request',
    invalid_header: 'err.bad_request',
    bad_request: 'err.bad_request',
    method_not_allowed: 'err.bad_request',
    unsupported_media_type: 'err.bad_request',
    insufficient_scope: 'err.insufficient_scope',
    pairing_closed: 'err.pairing_closed',
    pairing_busy: 'err.pairing_busy',
    pairing_expired: 'err.pairing_expired',
    invalid_pairing_code: 'err.invalid_pairing_code',
    not_found: 'err.not_found',
    rate_limited: 'err.rate_limited',
    server_busy: 'err.server_busy',
    app_backgrounded: 'err.app_backgrounded',
    model_unavailable: 'err.model_unavailable',
    model_changed: 'err.model_changed',
    model_not_found: 'err.model_not_found',
    consent_declined: 'err.consent_declined',
    consent_timeout: 'err.consent_timeout',
    escalation_off: 'err.escalation_off',
    egress_not_allowed: 'err.egress_not_allowed',
    context_length_exceeded: 'err.context_length_exceeded',
    unsupported_language: 'err.unsupported_language',
    request_too_large: 'err.request_too_large',
    origin_not_allowed: 'err.origin_not_allowed',
    cross_site: 'err.cross_site',
    misdirected_request: 'err.misdirected_request',
    expired_api_key: 'err.expired_api_key',
    invalid_api_key: 'err.invalid_api_key',
    internal: 'err.internal',
    incomplete: 'err.incomplete',
  };

  const state = {
    lang: 'en',
    hello: null,
    session: null,
    pairingId: null,
    history: [],
    // Sent with every chat request; kept in this tab only, like the language.
    reason: 'medium',
    maxTokens: null,
    // Reasoning blocks in the transcript, so a language switch can redraw their summaries.
    reasoningBlocks: [],
    controller: null,
    retryIndex: 0,
    retryTimer: null,
    languageTimer: null,
    mutedRegions: null,
  };
  const QUIET_REGIONS = ['messages', 'banner-unencrypted'];

  // Element id -> function giving its current text, so a language switch can redraw it.
  const slots = {};

  function byId(id) {
    return document.getElementById(id);
  }

  function show(id, visible) {
    byId(id).hidden = !visible;
  }

  function setText(id, text) {
    delete slots[id];
    byId(id).textContent = text;
  }

  function render(id, text) {
    slots[id] = text;
    byId(id).textContent = text();
  }

  function say(id, key, params) {
    render(id, function () { return t(key, params); });
  }

  function sayError(id, error) {
    render(id, function () { return describe(error); });
  }

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
  }

  // For parameterless text in built elements; applyStatic redraws it on a language switch.
  function localized(tag, className, key) {
    const node = element(tag, className, t(key));
    node.dataset.i18n = key;
    return node;
  }

  function clearChildren(node) {
    while (node.firstChild) node.removeChild(node.firstChild);
  }

  function token() {
    return sessionStorage.getItem(TOKEN_KEY);
  }

  function isLoopbackPage() {
    return LOOPBACK_HOSTS.indexOf(location.hostname) >= 0;
  }

  // MARK: - Language

  // Codes and kinds come from the server: a plain lookup would match "constructor" or "__proto__".
  function own(map, key) {
    return Object.prototype.hasOwnProperty.call(map, key) ? map[key] : undefined;
  }

  function phrase(key) {
    const entry = own(STRINGS, key);
    if (!entry) return '';
    const other = state.lang === 'es' ? 'en' : 'es';
    return entry[state.lang] || entry[other] || '';
  }

  // Values are substituted in one pass, so a server string containing "{x}" is never expanded.
  function t(key, params) {
    const noun = phrase(own(DEVICE_KEYS, hostKind()));
    const values = Object.assign({ device: noun, Device: noun.charAt(0).toUpperCase() + noun.slice(1) }, params);
    return phrase(key).replace(/\{(\w+)\}/g, function (whole, name) {
      const value = own(values, name);
      return value === undefined || value === null ? whole : String(value);
    });
  }

  // The table holds .one and .other only; CLDR's other Spanish categories ("many") read as .other.
  function plural(key, count, params) {
    const form = typeof count === 'number' && PLURAL_RULES[state.lang].select(count) === 'one' ? 'one' : 'other';
    return t(key + '.' + form, params);
  }

  function hostKind() {
    if (!state.hello) return 'any';
    return state.hello.host === 'cli' ? 'cli' : 'app';
  }

  function number(value) {
    return typeof value === 'number' && isFinite(value) ? NUMBER_FORMATS[state.lang].format(value) : '?';
  }

  function browserLanguage() {
    try {
      const saved = sessionStorage.getItem(LANG_KEY);
      if (LANGUAGES.indexOf(saved) >= 0) return saved;
    } catch (ignored) {
      // Storage refused: fall back to the browser's preference.
    }
    const preferred = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language];
    for (let index = 0; index < preferred.length; index += 1) {
      const match = /^(es|en)(-|$)/i.exec(String(preferred[index] || ''));
      if (match) return match[1].toLowerCase();
    }
    return 'en';
  }

  function applyStatic() {
    document.documentElement.lang = state.lang;
    document.title = t('doc.title');
    document.querySelectorAll('[data-i18n]').forEach(function (node) {
      const text = t(node.dataset.i18n);
      if (node.textContent !== text) node.textContent = text;
    });
    document.querySelectorAll('[data-i18n-placeholder]').forEach(function (node) {
      node.placeholder = t(node.dataset.i18nPlaceholder);
    });
    document.querySelectorAll('[data-i18n-aria-label]').forEach(function (node) {
      node.setAttribute('aria-label', t(node.dataset.i18nAriaLabel));
    });
    document.querySelectorAll('.language button').forEach(function (button) {
      button.setAttribute('aria-pressed', String(button.dataset.lang === state.lang));
    });
  }

  // Redraws text only: inputs, the transcript and pending requests are left alone, and nothing is fetched.
  function setLanguage(lang) {
    if (LANGUAGES.indexOf(lang) < 0) return;
    state.lang = lang;
    try {
      sessionStorage.setItem(LANG_KEY, lang);
    } catch (ignored) {
      // Not remembered across reloads; the switch still applies.
    }
    // Otherwise screen readers re-read every role label in the transcript and the unencrypted alert.
    // A switch inside the quiet period keeps the attributes saved by the first one.
    if (!state.mutedRegions) {
      state.mutedRegions = QUIET_REGIONS.map(function (id) {
        const node = byId(id);
        const before = node.getAttribute('aria-live');
        node.setAttribute('aria-live', 'off');
        return { node: node, before: before };
      });
    }
    applyStatic();
    Object.keys(slots).forEach(function (id) { byId(id).textContent = slots[id](); });
    state.reasoningBlocks.forEach(drawReasoning);
    fillReason();
    if (state.hello) {
      fillModels(state.hello.models || []);
      fillLength();
      buildGuide(state.hello, state.session);
      updateEgressBanner();
    }
    clearTimeout(state.languageTimer);
    state.languageTimer = setTimeout(function () {
      state.mutedRegions.forEach(function (region) {
        if (region.before === null) region.node.removeAttribute('aria-live');
        else region.node.setAttribute('aria-live', region.before);
      });
      state.mutedRegions = null;
      setText('language-status', t('lang.changed'));
    }, 500);
  }

  // MARK: - Requests

  async function api(path, options) {
    const headers = { Accept: 'application/json' };
    const settings = options || {};
    if (settings.auth && token()) headers.Authorization = 'Bearer ' + token();
    if (settings.body !== undefined) headers['Content-Type'] = 'application/json';
    return fetch(path, {
      method: settings.method || 'GET',
      headers: headers,
      body: settings.body === undefined ? undefined : JSON.stringify(settings.body),
      signal: settings.signal,
      cache: 'no-store',
      credentials: 'omit',
      redirect: 'error',
      referrerPolicy: 'no-referrer',
    });
  }

  async function errorOf(response) {
    let code = 'http_' + response.status;
    let message = '';
    try {
      const body = await response.json();
      if (body && body.error) {
        code = String(body.error.code || code);
        message = String(body.error.message || '');
      }
    } catch (ignored) {
      // Not JSON: describe() falls back to the status.
    }
    return { status: response.status, code: code, message: message };
  }

  // Known codes get page text; anything else shows the server's own (English, API) message.
  function describe(error) {
    const key = own(ERROR_KEYS, error.code);
    const limits = state.hello && state.hello.limits || {};
    if (key) {
      return t(key, { messages: number(limits.maxMessages), characters: number(limits.maxCharactersPerMessage) });
    }
    if (error.message) return t('err.server', { detail: error.message });
    return t('err.status', { status: error.status });
  }

  // MARK: - Session

  async function checkSession() {
    clearTimeout(state.retryTimer);
    if (!token()) {
      showPairing();
      return;
    }
    let response;
    try {
      response = await api('/api/session', { auth: true });
    } catch (ignored) {
      scheduleRetry();
      return;
    }
    if (response.status === 401) {
      sessionStorage.removeItem(TOKEN_KEY);
      showPairing('pair.sessionEnded');
      return;
    }
    if (!response.ok) {
      if (response.status >= 500 || response.status === 429) {
        scheduleRetry();
      } else {
        showPairing(null, await errorOf(response));
      }
      return;
    }
    const payload = await response.json();
    state.retryIndex = 0;
    show('banner-status', false);
    enterWorkspace(payload.hello, payload.session);
  }

  // Phone suspended or app in the background: the socket is gone, so keep asking with backoff.
  function scheduleRetry() {
    const delay = RETRY_DELAYS[Math.min(state.retryIndex, RETRY_DELAYS.length - 1)];
    state.retryIndex += 1;
    render('banner-status', function () { return t(own(RETRY_KEYS, hostKind()), { seconds: delay }); });
    show('banner-status', true);
    state.retryTimer = setTimeout(checkSession, delay * 1000);
  }

  async function logout() {
    try {
      await api('/api/session/logout', { method: 'POST', auth: true });
    } catch (ignored) {
      // The token is dropped locally either way.
    }
    sessionStorage.removeItem(TOKEN_KEY);
    state.hello = null;
    state.history = [];
    state.reasoningBlocks = [];
    clearChildren(byId('messages'));
    showPairing('pair.signedOut');
  }

  // MARK: - Pairing

  function showPairing(key, error) {
    show('loading', false);
    show('workspace', false);
    show('logout', false);
    setChatMode(false);
    setText('session-expiry', '');
    setText('server-name', '');
    show('pairing', true);
    show('pair-step-request', true);
    show('pair-step-code', false);
    state.pairingId = null;
    if (error) {
      sayError('pair-message', error);
    } else if (key) {
      say('pair-message', key);
    } else {
      setText('pair-message', '');
    }
  }

  async function requestPairing() {
    say('pair-message', 'pair.requesting');
    let response;
    try {
      response = await api('/pair', { method: 'POST', body: { name: byId('pair-name').value.slice(0, 60) } });
    } catch (ignored) {
      say('pair-message', 'pair.unreachable');
      return;
    }
    if (!response.ok) {
      sayError('pair-message', await errorOf(response));
      return;
    }
    const body = await response.json();
    state.pairingId = String(body.request || '');
    show('pair-step-request', false);
    show('pair-step-code', true);
    byId('pair-code').value = '';
    byId('pair-code').focus();
    render('pair-message', function () {
      return plural('pair.typeCode', body.attempts, { attempts: number(body.attempts) });
    });
  }

  async function claimPairing() {
    if (!state.pairingId) return;
    const code = byId('pair-code').value.replace(/\s+/g, '');
    let response;
    try {
      response = await api('/pair/' + encodeURIComponent(state.pairingId), { method: 'POST', body: { code: code } });
    } catch (ignored) {
      say('pair-message', 'pair.unreachable');
      return;
    }
    if (!response.ok) {
      const error = await errorOf(response);
      sayError('pair-message', error);
      if (error.code !== 'invalid_pairing_code') {
        show('pair-step-code', false);
        show('pair-step-request', true);
        state.pairingId = null;
      }
      return;
    }
    const body = await response.json();
    sessionStorage.setItem(TOKEN_KEY, String(body.token));
    state.pairingId = null;
    enterWorkspace(body.hello, body.session);
  }

  // MARK: - Workspace

  function enterWorkspace(hello, session) {
    state.hello = hello;
    state.session = session;
    show('loading', false);
    show('pairing', false);
    show('workspace', true);
    show('logout', true);
    setChatMode(true);
    setText('server-name', hello.serverName);
    if (session && session.expiresAt) {
      render('session-expiry', function () { return t('session.until', { time: clock(session.expiresAt) }); });
    }
    show('banner-unencrypted', !isLoopbackPage() || hello.observable === true);
    if (hello.observable === true) {
      render('banner-unencrypted-where', function () { return observableWhere(hello.interface); });
    } else {
      setText('banner-unencrypted-where', '');
    }
    render('guide-intro', function () { return t(hostKind() === 'cli' ? 'guide.intro.cli' : 'guide.intro.app'); });
    fillModels(hello.models || []);
    fillLength();
    buildGuide(hello, session);
    updateEgressBanner();
    if (guideRequested()) openGuide();
  }

  function observableWhere(network) {
    let name = t('net.unknown');
    const known = network && own(NETWORK_KEYS, network.kind);
    if (known) name = t(known);
    else if (network) name = t('net.named', { name: network.name || '?' });
    return t('net.where', { network: name });
  }

  function clock(seconds) {
    return TIME_FORMATS[state.lang].format(new Date(seconds * 1000));
  }

  function fillModels(models) {
    const select = byId('model');
    const previous = select.value;
    clearChildren(select);
    models.forEach(function (model) {
      select.appendChild(modelOption(model));
    });
    if (models.some(function (model) { return model.id === previous; })) select.value = previous;
    byId('send').disabled = models.length === 0;
    if (models.length === 0) say('chat-message', 'chat.noModels');
    showModelName();
  }

  // CSS truncates a long id; the title keeps the whole name.
  function showModelName() {
    const node = byId('current-model');
    const chosen = selectedModel();
    const name = chosen ? String(chosen.id) : '';
    node.textContent = name;
    node.title = name ? t('top.model', { model: name }) : '';
    show('current-model', Boolean(name && state.hello));
  }

  function modelOption(model) {
    const option = element('option', null, model.id + ' — ' + egressShort(model.egress));
    option.value = model.id;
    return option;
  }

  function selectedModel() {
    const id = byId('model').value;
    return (state.hello && state.hello.models || []).find(function (model) { return model.id === id; });
  }

  function egressShort(egress) {
    switch (egress && egress.class) {
      case 'on_device': return t('dest.short.on_device');
      case 'local_network': return t('dest.short.local_network');
      case 'cloud': return t('dest.short.cloud');
      default: return t('dest.short.unknown');
    }
  }

  function egressLong(egress) {
    switch (egress && egress.class) {
      case 'on_device':
        return t('dest.long.on_device');
      case 'local_network':
        return t('dest.long.local_network', { host: egress.host });
      case 'cloud':
        return t('dest.long.cloud', { provider: egress.provider || '?' });
      default:
        return t('dest.long.unknown');
    }
  }

  // The retention note is the integrator's free text in whatever language they wrote it, so it is quoted apart
  // with an unknown language instead of being spliced into a translated sentence.
  function describeEgress(parent, egress) {
    parent.appendChild(element('span', null, egressLong(egress)));
    const note = egress && egress.class === 'cloud' ? egress.retention : null;
    if (typeof note !== 'string' || !note) return;
    parent.appendChild(element('span', 'retention-label', ' ' + t('dest.retention') + ' '));
    const quoted = element('q', 'retention', note);
    quoted.setAttribute('lang', '');
    parent.appendChild(quoted);
  }

  function updateEgressBanner() {
    const model = selectedModel();
    const leaves = model && model.egress && model.egress.class !== 'on_device';
    const banner = byId('banner-egress');
    clearChildren(banner);
    if (leaves) describeEgress(banner, model.egress);
    show('banner-egress', Boolean(leaves));
  }

  // MARK: - Chat

  function addMessage(role, text) {
    const item = element('li', 'message-item ' + role);
    item.appendChild(localized('span', 'role', role === 'user' ? 'chat.role.user' : 'chat.role.assistant'));
    const body = element('div', 'content', text);
    item.appendChild(body);
    byId('messages').appendChild(item);
    show('empty-chat', false);
    item.scrollIntoView({ block: 'end' });
    return body;
  }

  function setBusy(busy) {
    show('send', !busy);
    show('stop', busy);
    byId('prompt').disabled = busy;
    byId('model').disabled = busy;
    byId('reason').disabled = busy;
    byId('length').disabled = busy;
    byId('clear').disabled = busy;
  }

  function savedReason() {
    let saved = null;
    try {
      saved = sessionStorage.getItem(REASON_KEY);
    } catch (ignored) {
      // No storage: the default below.
    }
    // The checkbox before the levels stored 'off' or 'on'.
    if (saved === 'off') return 'none';
    return REASON_LEVELS.some(function (level) { return level.effort === saved; }) ? saved : 'medium';
  }

  function fillReason() {
    const select = byId('reason');
    clearChildren(select);
    REASON_LEVELS.forEach(function (level) {
      const option = element('option', null, t(level.key));
      option.value = level.effort;
      select.appendChild(option);
    });
    select.value = state.reason;
  }

  function setReason(effort) {
    state.reason = effort;
    byId('reason').value = effort;
    try {
      sessionStorage.setItem(REASON_KEY, effort);
    } catch (ignored) {
      // Storage refused: the choice lasts until the page reloads.
    }
  }

  // A value above the cap would only be lowered by the server, so none is offered; a cap under every choice is
  // offered as it is.
  function lengthChoices(limits) {
    const cap = Number(limits.maxTokensCap);
    if (!(cap > 0)) return LENGTH_CHOICES.slice();
    const allowed = LENGTH_CHOICES.filter(function (tokens) { return tokens <= cap; });
    return allowed.length ? allowed : [Math.floor(cap)];
  }

  function savedLength() {
    try {
      const saved = parseInt(sessionStorage.getItem(LENGTH_KEY), 10);
      return isFinite(saved) ? saved : null;
    } catch (ignored) {
      return null;
    }
  }

  // The kept choice when this server still offers it, else the largest one within the server's default.
  function fillLength() {
    const limits = state.hello && state.hello.limits || {};
    const choices = lengthChoices(limits);
    const wanted = state.maxTokens !== null ? state.maxTokens : savedLength();
    const standard = Number(limits.maxTokensDefault);
    const within = choices.filter(function (tokens) { return tokens <= standard; });
    const fallback = within.length ? within[within.length - 1] : choices[0];
    state.maxTokens = choices.indexOf(wanted) >= 0 ? wanted : fallback;
    const select = byId('length');
    clearChildren(select);
    choices.forEach(function (tokens) {
      const option = element('option', null, t('chat.length.option', { tokens: number(tokens) }));
      option.value = String(tokens);
      select.appendChild(option);
    });
    select.value = String(state.maxTokens);
  }

  function setLength(tokens) {
    if (!isFinite(tokens)) return;
    state.maxTokens = tokens;
    try {
      sessionStorage.setItem(LENGTH_KEY, String(tokens));
    } catch (ignored) {
      // Storage refused: the choice lasts until the page reloads.
    }
  }

  // The answer as Markdown (a safe subset) after unwrapping \boxed{…}, built from elements and text nodes only.
  // Links are shown as text with their address; nothing in an answer becomes clickable.
  function renderAnswer(target, answer) {
    clearChildren(target);
    AnswerFormat.blocks(AnswerFormat.display(answer)).forEach(function (block) {
      target.appendChild(blockNode(block));
    });
  }

  function blockNode(block) {
    if (block.type === 'code') {
      const pre = element('pre', 'answer-code');
      pre.appendChild(element('code', null, block.text));
      return pre;
    }
    if (block.type === 'list') {
      const list = element(block.ordered ? 'ol' : 'ul', 'answer-list');
      if (block.ordered && block.start !== 1) list.start = block.start;
      block.items.forEach(function (item) {
        const entry = element('li');
        appendInlines(entry, item);
        list.appendChild(entry);
      });
      return list;
    }
    const paragraph = element('p', 'answer-paragraph');
    appendInlines(paragraph, block.inlines);
    return paragraph;
  }

  function appendInlines(parent, nodes) {
    nodes.forEach(function (node) {
      if (node.type === 'strong' || node.type === 'em') {
        const wrapper = element(node.type);
        appendInlines(wrapper, node.children);
        parent.appendChild(wrapper);
      } else if (node.type === 'code') {
        parent.appendChild(element('code', null, node.text));
      } else if (node.type === 'link') {
        const shown = AnswerFormat.linkText(node);
        parent.appendChild(element('span', 'answer-link', shown));
      } else {
        parent.appendChild(document.createTextNode(node.text));
      }
    });
  }

  // The clipboard API needs a secure page, which a LAN address over plain HTTP is not; there a hidden text area
  // is selected and copied instead. Its text is set through value, never parsed.
  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
    return new Promise(function (resolve, reject) {
      const area = element('textarea', 'copy-buffer');
      area.value = text;
      area.readOnly = true;
      document.body.appendChild(area);
      area.select();
      area.setSelectionRange(0, text.length);
      let copied = false;
      try {
        copied = document.execCommand('copy');
      } catch (ignored) {
        copied = false;
      }
      area.remove();
      if (copied) resolve();
      else reject(new Error('copy'));
    });
  }

  // Copies the answer as it is shown: boxes unwrapped, Markdown marks and escapes gone.
  function addCopyButton(target, answer) {
    if (!answer) return;
    const button = localized('button', 'copy-answer secondary', 'chat.copy');
    button.type = 'button';
    button.addEventListener('click', function () {
      copyText(AnswerFormat.shownText(answer)).then(function () {
        button.textContent = t('chat.copied');
      }, function () {
        button.textContent = t('chat.copyFailed');
      }).then(function () {
        setTimeout(function () { button.textContent = t('chat.copy'); }, 1500);
      });
    });
    target.parentNode.appendChild(button);
  }

  // A stream redraws at most once a frame: every draw parses the whole answer again.
  function scheduleAnswer(target, reply) {
    if (reply.drawPending) return;
    reply.drawPending = true;
    requestAnimationFrame(function () { flushAnswer(target, reply); });
  }

  function flushAnswer(target, reply) {
    if (!reply.drawPending) return;
    reply.drawPending = false;
    renderAnswer(target, reply.answer);
  }

  async function send() {
    const prompt = byId('prompt');
    const text = prompt.value.trim();
    const model = selectedModel();
    if (!text || !model || state.controller) return;
    const limits = state.hello && state.hello.limits || {};
    if (typeof limits.maxMessages === 'number' && state.history.length + 1 > limits.maxMessages) {
      say('chat-message', 'chat.tooManyMessages', { messages: number(limits.maxMessages) });
      return;
    }
    prompt.value = '';
    setText('chat-message', '');
    state.history.push({ role: 'user', content: text });
    addMessage('user', text);
    const target = addMessage('assistant', '');
    target.classList.add('pending');
    const controller = new AbortController();
    state.controller = controller;
    setBusy(true);
    // The answer and the reasoning are kept apart: only the answer goes back to the server on the next turn.
    const reply = { answer: '', reasoning: null, finish: null, drawPending: false };
    try {
      await streamChat(model.id, target, reply, controller.signal);
      flushAnswer(target, reply);
      state.history.push({ role: 'assistant', content: reply.answer });
      if (reply.reasoning && !reply.answer) {
        target.parentNode.appendChild(localized('p', 'reasoning-note', 'chat.reasoning.unfinished'));
      }
      if (reply.finish === 'content_filter') {
        target.parentNode.appendChild(localized('p', 'filtered-note', 'chat.contentFilter'));
      }
      addCopyButton(target, reply.answer);
    } catch (error) {
      // Stopped or failed mid-reasoning: the time so far is not a finished reasoning.
      if (reply.reasoning && reply.reasoning.ended === null) reply.reasoning.interrupted = true;
      if (controller.signal.aborted && reply.answer) {
        state.history.push({ role: 'assistant', content: reply.answer });
      } else {
        state.history.pop();
      }
      if (controller.signal.aborted) {
        target.classList.add('stopped');
        target.parentNode.appendChild(localized('span', 'stopped-note', 'chat.stoppedNote'));
        say('chat-message', 'chat.stopped');
      } else if (error && error.code) {
        target.classList.add('failed');
        sayError('chat-message', error);
        if (error.status === 401) {
          sessionStorage.removeItem(TOKEN_KEY);
          showPairing('pair.sessionEnded');
        }
      } else {
        target.classList.add('failed');
        say('chat-message', 'chat.lost');
        checkSession();
      }
    } finally {
      flushAnswer(target, reply);
      if (reply.reasoning) endReasoning(reply.reasoning);
      target.classList.remove('pending');
      state.controller = null;
      setBusy(false);
      prompt.focus();
    }
  }

  // Close-delimited SSE: data frames until "data: [DONE]"; an error frame ends the stream without it.
  async function streamChat(modelId, target, reply, signal) {
    const response = await api('/v1/chat/completions', {
      method: 'POST',
      auth: true,
      signal: signal,
      body: {
        model: modelId,
        messages: state.history,
        stream: true,
        reasoning_effort: state.reason,
        max_tokens: state.maxTokens,
      },
    });
    if (!response.ok) throw await errorOf(response);
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    for (;;) {
      const chunk = await reader.read();
      if (chunk.done) break;
      buffer += decoder.decode(chunk.value, { stream: true });
      let boundary = buffer.indexOf('\n\n');
      while (boundary >= 0) {
        const frame = buffer.slice(0, boundary);
        buffer = buffer.slice(boundary + 2);
        const data = frameData(frame);
        if (data === '[DONE]') return;
        if (data !== null) {
          const event = JSON.parse(data);
          if (event.error) {
            throw { status: 200, code: String(event.error.code || 'internal'), message: String(event.error.message || '') };
          }
          const choice = event.choices && event.choices[0] || {};
          const delta = choice.delta || {};
          if (typeof choice.finish_reason === 'string') reply.finish = choice.finish_reason;
          // The server's own member: the reasoning budget closed the block before the model did.
          const cut = event.tonamox && event.tonamox.reasoning && event.tonamox.reasoning.cut === true;
          if (cut && reply.reasoning) {
            reply.reasoning.cut = true;
            drawReasoning(reply.reasoning);
          }
          if (typeof delta.reasoning_content === 'string' && delta.reasoning_content) {
            if (!reply.reasoning) reply.reasoning = reasoningBlock(target);
            const shown = reply.reasoning.text;
            shown.textContent += shown.textContent ? delta.reasoning_content : delta.reasoning_content.trimStart();
          }
          if (typeof delta.content === 'string' && delta.content) {
            if (reply.reasoning) endReasoning(reply.reasoning);
            reply.answer += delta.content;
            scheduleAnswer(target, reply);
          }
        }
        boundary = buffer.indexOf('\n\n');
      }
    }
    throw { status: 0, code: 'incomplete', message: '' };
  }

  // A native disclosure, collapsed by default. It is built once per reply and only its texts change afterwards, so
  // the reader's open or closed choice survives the rest of the stream.
  function reasoningBlock(target) {
    const block = {
      details: element('details', 'reasoning'),
      label: element('span', 'reasoning-label'),
      text: element('div', 'reasoning-text'),
      started: performance.now(),
      ended: null,
      interrupted: false,
      cut: false,
    };
    const summary = element('summary');
    summary.appendChild(block.label);
    block.details.appendChild(summary);
    block.details.appendChild(block.text);
    target.parentNode.insertBefore(block.details, target);
    state.reasoningBlocks.push(block);
    drawReasoning(block);
    return block;
  }

  // From the first reasoning delta to the first answer delta, or to the end of the stream.
  function endReasoning(block) {
    if (block.ended !== null) return;
    block.ended = performance.now();
    drawReasoning(block);
  }

  function drawReasoning(block) {
    let text = t('chat.reasoning.live');
    if (block.interrupted) {
      text = t('chat.reasoning.interrupted');
    } else if (block.ended !== null && block.cut) {
      const elapsed = block.ended - block.started;
      const seconds = Math.round(elapsed / 1000);
      text = elapsed < 1000 ? t('chat.reasoning.cut.brief') : plural('chat.reasoning.cut', seconds, { seconds: number(seconds) });
    } else if (block.ended !== null) {
      const elapsed = block.ended - block.started;
      const seconds = Math.round(elapsed / 1000);
      text = elapsed < 1000 ? t('chat.reasoning.brief') : plural('chat.reasoning.done', seconds, { seconds: number(seconds) });
    }
    block.label.textContent = text;
  }

  function frameData(frame) {
    const lines = frame.split('\n').filter(function (line) { return line.indexOf('data: ') === 0; });
    if (lines.length === 0) return null;
    return lines.map(function (line) { return line.slice(6); }).join('\n');
  }

  function stop() {
    if (state.controller) state.controller.abort();
  }

  function clearConversation() {
    state.history = [];
    state.reasoningBlocks = [];
    clearChildren(byId('messages'));
    show('empty-chat', true);
    setText('chat-message', '');
  }

  // MARK: - Guide

  function guideRequested() {
    return GUIDE_HASHES.indexOf(location.hash) >= 0;
  }

  function setChatMode(on) {
    document.body.classList.toggle('in-chat', on);
    show('open-guide', on);
    if (!on) {
      show('current-model', false);
      closeGuide();
    }
  }

  // showModal gives the focus trap, Esc and an inert page behind; there is no guide before pairing.
  function openGuide() {
    const dialog = byId('guide-dialog');
    if (dialog.open || !state.hello || byId('workspace').hidden) return;
    dialog.showModal();
  }

  function closeGuide() {
    const dialog = byId('guide-dialog');
    if (dialog.open) dialog.close();
  }

  function guideClosed() {
    if (guideRequested()) history.replaceState(null, '', location.pathname);
    if (!byId('open-guide').hidden) byId('open-guide').focus();
  }

  function buildGuide(hello, session) {
    const root = byId('guide-body');
    clearChildren(root);
    const origin = location.origin;
    const features = hello.features || [];
    const has = function (name) { return features.indexOf(name) >= 0; };
    const limits = hello.limits || {};
    const fromCLI = hello.host === 'cli';

    const where = section(root, 'guide.where.title');
    if (hello.exposure === 'loopback' && fromCLI) {
      paragraph(where, t('guide.where.cliLoopback', { port: hello.port }));
    } else if (hello.exposure === 'loopback') {
      paragraph(where, t('guide.where.appLoopback', { port: hello.port }));
      code(where, 'iproxy -s 127.0.0.1 ' + hello.port + ':' + hello.port);
      paragraph(where, t('guide.where.forwarderPort'));
    } else {
      const network = hello.interface || {};
      paragraph(where, t('guide.where.interface', { name: network.name || '?', address: network.address || '?',
        port: hello.port }));
      if (network.peerLock === 'first_paired_peer') paragraph(where, t('guide.where.peerLock'));
      if (network.idleMinutes) {
        paragraph(where, plural('guide.where.idle', network.idleMinutes, { minutes: number(network.idleMinutes) }));
      }
    }
    if (hello.foreground === true) {
      paragraph(where, t('guide.where.foreground'));
    } else if (fromCLI) {
      paragraph(where, t('guide.where.cliRunning'));
    }

    const models = section(root, 'guide.models.title');
    const modelList = element('ul', 'plain');
    (hello.models || []).forEach(function (model) {
      modelList.appendChild(modelItem(model));
    });
    if ((hello.models || []).length === 0) modelList.appendChild(element('li', 'muted', t('guide.models.none')));
    models.appendChild(modelList);

    const bounds = section(root, 'guide.limits.title');
    list(bounds, [
      t('guide.limits.queue', { seconds: number(limits.queueWaitSeconds || 30) }),
      t('guide.limits.tokens', { standard: number(limits.maxTokensDefault), cap: number(limits.maxTokensCap) }),
      t('guide.limits.rate', { count: number(limits.chatRequestsPerMinute) }),
      t('guide.limits.size', { messages: number(limits.maxMessages), characters: number(limits.maxCharactersPerMessage),
        body: kib(limits.chatBodyBytes) }),
      t('guide.limits.session', { idle: number(limits.browserIdleMinutes), hours: number(limits.browserLifetimeHours) }),
      t('guide.limits.unsupported'),
    ]);

    if (has('openai_api')) {
      const client = section(root, 'guide.api.title');
      const keys = hello.apiKeys || {};
      let headerFile = '"$HOME/.tonamox-key.header"';
      if (keys.keyDelivery === 'header_file') {
        headerFile = t('guide.ph.file');
        paragraph(client, t('guide.api.cliKey', { file: headerFile }));
      } else {
        const days = keys.defaultLifetimeDays || 7;
        paragraph(client, plural('guide.api.appKey', days, { days: number(days) }));
        code(client, '(umask 077; cat > "$HOME/.tonamox-key.header")');
        paragraph(client, t('guide.api.paste'));
      }
      code(client, 'curl -sS -H @' + headerFile + ' ' + origin + '/v1/models');
      const firstModel = (hello.models || [])[0];
      const modelId = firstModel ? firstModel.id : t('guide.ph.model');
      code(client, 'curl -sS -H @' + headerFile + ' -H \'Content-Type: application/json\' \\\n'
        + '  -d \'{"model":"' + modelId + '","messages":[{"role":"user","content":"'
        + t('guide.example.greeting') + '"}]}\' \\\n'
        + '  ' + origin + '/v1/chat/completions');
      paragraph(client, t('guide.api.compatible'));
      code(client, origin + '/v1');
      paragraph(client, t('guide.api.noArgv'));
    }

    if (has('ingest') && hello.ingest) {
      const ingest = section(root, 'guide.ingest.title');
      paragraph(ingest, t('guide.ingest.ticket', { minutes: number(hello.ingest.ticketMinutes),
        standard: kib(hello.ingest.defaultMaxBytes), max: kib(hello.ingest.maxBytes) }));
      code(ingest, t('guide.ph.command') + ' 2>&1 | curl -sS --data-binary @- ' + origin + '/i/<ticket>');
      paragraph(ingest, t('guide.ingest.untrusted', { count: number(hello.ingest.postsPerMinute) }));
    }

    if (has('scripts') && hello.scripts && hello.scripts.length) {
      const scripts = section(root, 'guide.scripts.title');
      paragraph(scripts, t('guide.scripts.compare'));
      hello.scripts.forEach(function (script) {
        scripts.appendChild(element('h4', null, script.name));
        code(scripts, script.sha256);
        paragraph(scripts, t('guide.scripts.macos'));
        code(scripts, fetchLine(origin, script, 'shasum -a 256 -c -'));
        paragraph(scripts, t('guide.scripts.linux'));
        code(scripts, fetchLine(origin, script, 'sha256sum -c -'));
      });
    }

    if (fromCLI) {
      const cli = section(root, 'guide.cli.title');
      list(cli, [t('guide.cli.model'), t('guide.cli.browser'), t('guide.cli.stop')]);
    }

    if (!fromCLI) {
      const phone = section(root, 'guide.phone.title');
      list(phone, [
        t('guide.phone.start'),
        t('guide.phone.pairing'),
        t('guide.phone.keys'),
        t('guide.phone.models'),
        t(has('ingest') ? 'guide.phone.ingestOn' : 'guide.phone.ingestOff'),
        t(has('scripts') ? 'guide.phone.scriptsOn' : 'guide.phone.scriptsOff'),
        t('guide.phone.hosts'),
      ]);
    }

    if (session) {
      const mine = section(root, 'guide.session.title');
      // The server stores "browser" when the name field was left empty.
      const label = !session.label || session.label === 'browser' ? t('guide.session.unnamed') : session.label;
      const scopes = (session.scopes || []).map(function (id) {
        const key = own(SCOPE_KEYS, id);
        return key ? t(key) : String(id);
      });
      paragraph(mine, t('guide.session.who', { label: label, scopes: scopes.join(', ') }));
      if (session.expiresAt) {
        paragraph(mine, t('guide.session.expiry', { time: clock(session.expiresAt),
          minutes: number(Math.round((session.idleSeconds || 0) / 60)) }));
      }
      paragraph(mine, t('guide.session.tab'));
    }
  }

  function modelItem(model) {
    const item = element('li');
    item.appendChild(element('code', null, model.id));
    const detail = model.contextLength ? t('guide.models.context', { tokens: number(model.contextLength) }) : '';
    item.appendChild(element('span', 'muted', detail));
    const destination = element('p', 'small');
    describeEgress(destination, model.egress);
    item.appendChild(destination);
    return item;
  }

  function fetchLine(origin, script, verifier) {
    return 'f=$(mktemp) && curl -fsS ' + origin + script.path + ' -o "$f" && echo \'' + script.sha256
      + '  \'"$f" | ' + verifier;
  }

  function kib(bytes) {
    if (!bytes) return '?';
    return bytes >= 1048576 ? number(bytes / 1048576) + ' MiB' : number(Math.round(bytes / 1024)) + ' KiB';
  }

  function section(root, titleKey) {
    const node = element('section', 'guide-section');
    node.appendChild(element('h3', null, t(titleKey)));
    root.appendChild(node);
    return node;
  }

  function paragraph(parent, text) {
    parent.appendChild(element('p', null, text));
  }

  function list(parent, texts) {
    const node = element('ul', 'plain');
    texts.forEach(function (text) { node.appendChild(element('li', null, text)); });
    parent.appendChild(node);
  }

  function code(parent, text) {
    const wrapper = element('div', 'code-block');
    const pre = element('pre');
    pre.appendChild(element('code', null, text));
    wrapper.appendChild(pre);
    if (navigator.clipboard && window.isSecureContext) {
      const copy = element('button', 'copy secondary', t('guide.copy'));
      copy.type = 'button';
      copy.addEventListener('click', function () {
        navigator.clipboard.writeText(text).then(function () {
          copy.textContent = t('guide.copied');
          setTimeout(function () { copy.textContent = t('guide.copy'); }, 1500);
        });
      });
      wrapper.appendChild(copy);
    }
    parent.appendChild(wrapper);
  }

  // MARK: - Wiring

  function start() {
    state.lang = browserLanguage();
    // showModal makes the header inert, so the open guide carries its own copy of the switch.
    const guideLanguage = byId('language').cloneNode(true);
    guideLanguage.removeAttribute('id');
    byId('guide-close').before(guideLanguage);
    applyStatic();
    show('banner-unencrypted', !isLoopbackPage());
    document.querySelectorAll('.language button').forEach(function (button) {
      button.addEventListener('click', function () { setLanguage(button.dataset.lang); });
    });
    byId('pair-request').addEventListener('click', requestPairing);
    byId('pair-claim').addEventListener('click', claimPairing);
    byId('pair-restart').addEventListener('click', function () { showPairing(); });
    byId('pair-code').addEventListener('keydown', function (event) {
      if (event.key === 'Enter') claimPairing();
    });
    byId('logout').addEventListener('click', logout);
    byId('send').addEventListener('click', send);
    byId('stop').addEventListener('click', stop);
    byId('clear').addEventListener('click', clearConversation);
    byId('model').addEventListener('change', updateEgressBanner);
    byId('model').addEventListener('change', showModelName);
    state.reason = savedReason();
    fillReason();
    byId('reason').addEventListener('change', function () { setReason(byId('reason').value); });
    byId('length').addEventListener('change', function () { setLength(parseInt(byId('length').value, 10)); });
    byId('open-guide').addEventListener('click', openGuide);
    byId('guide-close').addEventListener('click', closeGuide);
    const dialog = byId('guide-dialog');
    dialog.addEventListener('close', guideClosed);
    // The sheet fills the dialog box, so a click that targets the dialog itself landed on the backdrop. A drag
    // that starts in the sheet and ends outside also targets the dialog, so the press must start there too.
    let pressOnBackdrop = false;
    dialog.addEventListener('pointerdown', function (event) {
      pressOnBackdrop = event.target === dialog;
    });
    dialog.addEventListener('click', function (event) {
      if (pressOnBackdrop && event.target === dialog) closeGuide();
      pressOnBackdrop = false;
    });
    window.addEventListener('hashchange', function () {
      if (guideRequested()) openGuide();
      else closeGuide();
    });
    byId('prompt').addEventListener('keydown', function (event) {
      if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
        event.preventDefault();
        send();
      }
    });
    checkSession();
  }

  document.addEventListener('DOMContentLoaded', start);
})();

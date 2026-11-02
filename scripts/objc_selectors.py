"""Rewrite tip Swift that uses `#selector`/`@objc` into code that compiles without an Objective-C runtime.

Linux Swift has no Objective-C interop, so `#selector(...)` and `@objc` are compile errors. Compat AppKit instead
dispatches target-action by name through `NSSelectorDispatching` (Sources/Compat/AppKit/View.swift). This module:

- names each selector the way the Objective-C runtime would (`f` → "f", `f(_:)` → "f:", `f(_:in:)` → "f:in:");
- rewrites `#selector(...)` to `Selector("name")` and drops `@objc`;
- appends, per class that declared `@objc` methods, an `NSSelectorDispatching` conformance whose `switch` reaches
  exactly those methods (in the same file, so `private` ones stay reachable).

Only the forms tip actually uses are supported; anything else raises, so a new form is a visible generator change.
"""
import re

_FUNC = re.compile(r'@objc\b(?:\s+(?:private|fileprivate|internal|public|override|final|dynamic))*\s+func\s+(\w+)\s*\(')
_TYPE = re.compile(r'\b(class|struct|enum|extension)\s+(?!func\b|var\b|let\b)(\w+(?:\.\w+)*)')
_SELECTOR = re.compile(r'#selector\(([^()]*(?:\([^()]*\))?)\)')


def _code_mask(source):
    """A copy of `source` with string literals and comments blanked, so brace and keyword scans see only code."""
    out, i, n = list(source), 0, len(source)
    while i < n:
        if source.startswith('//', i):
            j = source.find('\n', i)
            j = n if j < 0 else j
            out[i:j] = ' ' * (j - i)
            i = j
        elif source.startswith('/*', i):
            j = source.find('*/', i) + 2
            out[i:j] = [c if c == '\n' else ' ' for c in source[i:j]]
            i = j
        elif source[i] == '"':
            if source.startswith('"""', i):
                j = source.find('"""', i + 3) + 3
            else:
                j, depth = i + 1, 0
                while j < n:
                    if source[j] == '\\' and source.startswith('\\(', j):
                        depth += 1
                        j += 2
                        continue
                    if source[j] == '\\':
                        j += 2
                        continue
                    if depth and source[j] == '(':
                        depth += 1
                    elif depth and source[j] == ')':
                        depth -= 1
                    elif not depth and source[j] == '"':
                        break
                    j += 1
                j += 1
            out[i:j] = [c if c == '\n' else ' ' for c in source[i:j]]
            i = j
        else:
            i += 1
    return ''.join(out)


def _matching_paren(text, open_index):
    depth = 0
    for k in range(open_index, len(text)):
        if text[k] == '(':
            depth += 1
        elif text[k] == ')':
            depth -= 1
            if depth == 0:
                return k
    raise ValueError('unbalanced parentheses')


def _split_top(params):
    parts, depth, start = [], 0, 0
    for k, c in enumerate(params):
        if c in '([<':
            depth += 1
        elif c in ')]>':
            depth -= 1
        elif c == ',' and depth == 0:
            parts.append(params[start:k])
            start = k + 1
    if params.strip():
        parts.append(params[start:])
    return [p.strip() for p in parts]


def _parse_params(params):
    """[(label, type)] of a Swift parameter list; label is '_' for an unlabeled one."""
    result = []
    for p in _split_top(params):
        names, _, typ = p.partition(':')
        words = names.split()
        typ = typ.split('=')[0].strip()
        result.append((words[0], typ))
    return result


def _objc_name(name, labels):
    if not labels:
        return name
    first, rest = labels[0], labels[1:]
    if first != '_':
        raise ValueError(f'{name}: a labeled first parameter ({first}:) needs Swift\'s preposition rules; not supported')
    return name + ':' + ''.join(f'{label}:' for label in rest)


def declarations(source):
    """[(type path, method, [(label, type)], start, end)] for every `@objc func`, with its enclosing type path."""
    code = _code_mask(source)
    # Type scopes: (path, body start, body end).
    scopes, stack = [], []
    pending = None
    for m in re.finditer(r'[{}]|' + _TYPE.pattern, code):
        token = m.group(0)
        if token == '{':
            stack.append((pending, m.end()))
            pending = None
        elif token == '}':
            entry, start = stack.pop()
            if entry is not None:
                scopes.append((entry, start, m.start()))
        else:
            enclosing = [e for e, _ in stack if e is not None]
            name = m.group(2)
            pending = name if m.group(1) == 'extension' or not enclosing else enclosing[-1] + '.' + name
    found = []
    for m in _FUNC.finditer(code):
        close = _matching_paren(code, m.end() - 1)
        params = _parse_params(source[m.end():close])
        owners = [s for s in scopes if s[1] <= m.start() < s[2]]
        owner = max(owners, key=lambda s: s[1])[0]
        found.append((owner, m.group(1), params, m.start(), close))
    return found


def selector_name(expression, decls):
    """The Objective-C name a `#selector(expression)` produces."""
    m = re.fullmatch(r'\s*(?:(\w+(?:\.\w+)*)\.)?(\w+)(?:\(([\w:]*)\))?\s*', expression)
    if not m:
        raise ValueError(f'#selector({expression}): unsupported form')
    owner, name, labels = m.groups()
    if labels is not None:
        return _objc_name(name, [l for l in labels.split(':') if l])
    candidates = {(o, tuple(l for l, _ in p)) for o, n, p, _, _ in decls
                  if n == name and (owner is None or o == owner or o.endswith('.' + owner))}
    shapes = {labels for _, labels in candidates}
    if len(shapes) != 1:
        raise ValueError(f'#selector({expression}): {len(shapes)} matching @objc declarations')
    return _objc_name(name, list(shapes.pop()))


def rewrite_selectors(source, decls):
    return _SELECTOR.sub(lambda m: f'Selector("{selector_name(m.group(1), decls)}")', source)


def strip_objc(source):
    return re.sub(r'@objc\s+', '', source)


def dispatch_extensions(decls):
    """`NSSelectorDispatching` conformances, one per class, reaching exactly its `@objc` methods."""
    by_owner = {}
    for owner, name, params, _, _ in decls:
        by_owner.setdefault(owner, []).append((name, params))
    blocks = []
    for owner, methods in by_owner.items():
        cases, names = [], []
        for name, params in methods:
            if len(params) > 1:
                raise ValueError(f'{owner}.{name}: target-action methods take at most the sender')
            selector = _objc_name(name, [l for l, _ in params])
            names.append(f'"{selector}"')
            if not params:
                cases.append(f'        case "{selector}": {name}()')
            else:
                typ = params[0][1]
                if typ in ('Any?', 'Any'):
                    cases.append(f'        case "{selector}": {name}(argument)')
                else:
                    cases.append(f'        case "{selector}":\n'
                                 f'            guard let sender = argument as? {typ} else {{ return false }}\n'
                                 f'            {name}(sender)')
        blocks.append(
            f'extension {owner}: NSSelectorDispatching {{\n'
            f'    func compatPerform(_ selector: Selector, with argument: Any?) -> Bool {{\n'
            f'        switch selector.name {{\n' + '\n'.join(cases) + '\n'
            f'        default: return false\n'
            f'        }}\n'
            f'        return true\n'
            f'    }}\n'
            f'    func compatResponds(to selector: Selector) -> Bool {{ [{", ".join(names)}].contains(selector.name) }}\n'
            f'}}\n')
    return '\n'.join(blocks)


def drop_declaration(source, header):
    """Removes the declaration whose first line starts with `header` (and its doc comment), braces matched in code."""
    start = source.find(header)
    if start < 0:
        raise ValueError(f'{header!r} not found')
    while True:  # Its doc comment goes with it.
        previous = source.rfind('\n', 0, start - 1) + 1
        if source[previous:start].lstrip().startswith('///'):
            start = previous
        else:
            break
    code = _code_mask(source)
    depth, k = 0, code.index('{', start)
    for k in range(k, len(code)):
        if code[k] == '{':
            depth += 1
        elif code[k] == '}':
            depth -= 1
            if depth == 0:
                break
    end = k + 1
    if source[end:end + 1] == '\n':
        end += 1
    return source[:start] + source[end:]


def rewrite_perform(source):
    """`x?.perform(Selector("m"))` → `NSPerform(x, Selector("m"))`: `perform` on an `AnyObject` is Objective-C's
    dynamic dispatch; compat's `NSPerform` reaches the target's `NSSelectorDispatching` conformance instead."""
    return re.sub(r'(\w+)\??\.perform\((Selector\("[\w:]+"\)(?:\s*:\s*Selector\("[\w:]+"\))?|[^()]*\?\s*Selector\("[\w:]+"\)\s*:\s*Selector\("[\w:]+"\))\)',
                  r'NSPerform(\1, \2)', source)


def port(source):
    """`#selector` → `Selector("…")`, `@objc` dropped, dispatch conformances appended."""
    decls = declarations(source)
    body = rewrite_perform(strip_objc(rewrite_selectors(source, decls)))
    extensions = dispatch_extensions(decls)
    return body + ('\n// MARK: - Target-action by name (generated; see scripts/objc_selectors.py)\n\n' + extensions
                   if extensions else '')

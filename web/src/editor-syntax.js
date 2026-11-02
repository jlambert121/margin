/* Editor syntax. */
'use strict';
window.MarginEditorSyntax = () => {
  const $ = selector => document.querySelector(selector);
  const { markdown, markdownLanguage, codeLanguages, parseMixed, yamlLanguage, tagHighlighter, tags, languageDataProp } = MarginEditor;
  // Front matter is a block of its own, parsed as YAML, so its closing "---" does not
  // turn the YAML above it into a heading.
  const fm = MarginMarkdown.frontmatter;
  const frontmatterSyntax = {
    defineNodes: [{ name: 'Frontmatter', block: true }, 'FrontmatterMark', 'FrontmatterContent'],
    parseBlock: [{
      name: 'Frontmatter',
      before: 'HorizontalRule',
      parse(cx, line) {
        if (cx.lineStart !== 0 || !fm.open.test(line.text) || !fm.key.test(cx.peekLine())) return false;
        const children = [cx.elt('FrontmatterMark', 0, line.text.length)];
        let contentFrom = -1, end = line.text.length, closed = false;
        while (cx.nextLine()) {
          const from = cx.lineStart, to = from + line.text.length;
          if (fm.close.test(line.text)) {
            if (contentFrom >= 0) children.push(cx.elt('FrontmatterContent', contentFrom, end));
            children.push(cx.elt('FrontmatterMark', from, to));
            end = to; closed = true; cx.nextLine();
            break;
          }
          if (contentFrom < 0) contentFrom = from;
          end = to;
        }
        // Without a closing line it runs to the end of the document.
        if (!closed && contentFrom >= 0) children.push(cx.elt('FrontmatterContent', contentFrom, end));
        cx.addElement(cx.elt('Frontmatter', 0, end, children));
        return true;
      },
    }],
    wrap: parseMixed(node => node.name === 'FrontmatterContent' ? { parser: yamlLanguage.parser } : null),
  };
  // GFM Markdown with list continuation on Enter, pasting a URL over text as a link,
  // and fenced code parsed in the language its info string names.
  const markdownSupport = markdown({ base: markdownLanguage, codeLanguages, completeHTMLTags: false, extensions: frontmatterSyntax });
  // Single quotes are left out because they are usually apostrophes in prose.
  const markdownBrackets = markdownSupport.language.data.of({ closeBrackets: { brackets: ['(', '[', '{', '"', '`'] } });
  // Token classes for code inside fenced blocks. Markdown's own syntax is left to live preview.
  const codeHighlighter = tagHighlighter([
    { tag: [tags.keyword, tags.modifier, tags.self, tags.operatorKeyword, tags.controlKeyword, tags.definitionKeyword, tags.moduleKeyword], class: 'cm-code-keyword' },
    { tag: [tags.string, tags.special(tags.string), tags.character, tags.attributeValue, tags.docString], class: 'cm-code-string' },
    { tag: [tags.number, tags.bool, tags.null, tags.atom, tags.unit, tags.color], class: 'cm-code-number' },
    { tag: [tags.comment, tags.lineComment, tags.blockComment, tags.docComment], class: 'cm-code-comment' },
    { tag: [tags.function(tags.variableName), tags.function(tags.propertyName), tags.macroName], class: 'cm-code-function' },
    { tag: [tags.typeName, tags.className, tags.namespace, tags.standard(tags.variableName)], class: 'cm-code-type' },
    { tag: [tags.propertyName, tags.attributeName, tags.labelName], class: 'cm-code-property' },
    { tag: [tags.tagName, tags.angleBracket], class: 'cm-code-tag' },
    { tag: [tags.regexp, tags.escape, tags.special(tags.variableName)], class: 'cm-code-regexp' },
    { tag: [tags.meta, tags.annotation, tags.processingInstruction, tags.heading], class: 'cm-code-meta' },
    { tag: tags.inserted, class: 'cm-code-inserted' },
    { tag: tags.deleted, class: 'cm-code-deleted' },
    { tag: tags.invalid, class: 'cm-code-invalid' },
  ], { scope: type => type.prop(languageDataProp) !== markdownSupport.language.data });
  return { markdownSupport, markdownBrackets, codeHighlighter };
};

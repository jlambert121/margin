// The editor's only entry into CodeMirror, markdown-it, and DOMPurify.
// scripts/build-editor.sh bundles this into web/vendor/codemirror.bundle.js as
// the global MarginEditor.
export { EditorState, EditorSelection, ChangeSet, StateField, StateEffect, Compartment, Annotation, Prec } from '@codemirror/state';
export { EditorView, Decoration, WidgetType, keymap, placeholder, drawSelection } from '@codemirror/view';
export { defaultKeymap, indentWithTab } from '@codemirror/commands';
export { syntaxTree, ensureSyntaxTree, syntaxHighlighting, languageDataProp } from '@codemirror/language';
export { tags, tagHighlighter } from '@lezer/highlight';
export { closeBrackets, closeBracketsKeymap } from '@codemirror/autocomplete';
export { markdown, markdownLanguage } from '@codemirror/lang-markdown';
// Fenced code highlighting for every language CodeMirror knows. Each language
// loads through a dynamic import, which the single-file bundle inlines.
export { languages as codeLanguages } from '@codemirror/language-data';
// Comparing the document with a newer version of its file on disk.
export { unifiedMergeView, getChunks, getOriginalDoc, originalDocChangeEffect } from '@codemirror/merge';
export { default as MarkdownIt } from 'markdown-it';
export { default as DOMPurify } from 'dompurify';

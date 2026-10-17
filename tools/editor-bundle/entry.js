// The editor's only entry into CodeMirror, markdown-it, and DOMPurify.
// scripts/build-editor.sh bundles this into web/vendor/codemirror.bundle.js as
// the global MarginEditor.
export { EditorState, EditorSelection, ChangeSet, StateField, StateEffect, Compartment, Annotation, Prec } from '@codemirror/state';
export { EditorView, Decoration, WidgetType, keymap, placeholder, drawSelection } from '@codemirror/view';
export { defaultKeymap, indentWithTab } from '@codemirror/commands';
export { LanguageSupport, syntaxTree, ensureSyntaxTree } from '@codemirror/language';
// The pieces of markdown() the editor uses. markdown() itself also brings in the
// HTML language for tag completion and HTML highlighting, which the editor does
// not use.
export { markdownLanguage, markdownKeymap, pasteURLAsLink } from '@codemirror/lang-markdown';
// Comparing the document with a newer version of its file on disk.
export { unifiedMergeView, getChunks, getOriginalDoc, originalDocChangeEffect } from '@codemirror/merge';
export { default as MarkdownIt } from 'markdown-it';
export { default as DOMPurify } from 'dompurify';

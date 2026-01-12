import type { GenerateClaudeMdInput, Language } from '../types.js';

const languageDisplayNames: Record<Language, string> = {
  typescript: 'TypeScript',
  javascript: 'JavaScript',
  python: 'Python',
  rust: 'Rust',
  go: 'Go',
};

export function generateClaudeMd(input: GenerateClaudeMdInput): string {
  const { name, description, preferences } = input;
  const sections: string[] = [];

  sections.push(`# ${name}`);
  sections.push('');

  sections.push('## Overview');
  sections.push('');
  sections.push(description);
  sections.push('');

  const hasLanguage = preferences?.language;
  const hasFramework = preferences?.framework;

  if (hasLanguage || hasFramework) {
    sections.push('## Tech Stack');
    sections.push('');

    if (hasLanguage) {
      const displayName = languageDisplayNames[preferences.language!];
      sections.push(`- **Language:** ${displayName}`);
    }

    if (hasFramework) {
      sections.push(`- **Framework:** ${preferences.framework}`);
    }

    sections.push('');
  }

  sections.push('## Status');
  sections.push('');
  sections.push('This project is in its initial v1 bootstrap phase.');
  sections.push('');

  sections.push('## Development');
  sections.push('');
  sections.push('> This section will be updated as the project evolves.');
  sections.push('');

  return sections.join('\n');
}

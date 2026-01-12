import type { BuildPromptInput, Language } from '../types.js';

const languageDisplayNames: Record<Language, string> = {
  typescript: 'TypeScript',
  javascript: 'JavaScript',
  python: 'Python',
  rust: 'Rust',
  go: 'Go',
};

export function buildCreationPrompt(input: BuildPromptInput): string {
  const { name, description, preferences } = input;
  const sections: string[] = [];

  sections.push(`Build a working v1 of "${name}".`);
  sections.push('');
  sections.push(`## Description`);
  sections.push(description);
  sections.push('');

  if (preferences?.language || preferences?.framework) {
    sections.push('## Technical Requirements');

    if (preferences.language) {
      const displayName = languageDisplayNames[preferences.language];
      sections.push(`- Use ${displayName} as the primary language`);
    }

    if (preferences.framework) {
      sections.push(`- Use ${preferences.framework} as the framework`);
    }

    sections.push('');
  }

  sections.push('## Goals');
  sections.push('');
  sections.push('Focus on creating a working, functional implementation. Prioritize:');
  sections.push('');
  sections.push('1. **Working code** - The project should run without errors');
  sections.push('2. **Core functionality** - Implement the main features described above');
  sections.push('3. **README** - Include a README.md with clear usage instructions on how to run the project');
  sections.push('4. **Simplicity** - Keep the initial version simple and not perfect');
  sections.push('');

  sections.push('## Deliverables');
  sections.push('');
  sections.push('- Complete, runnable source code');
  sections.push('- README.md with setup and usage instructions');
  sections.push('- A way to start/run/test the project');
  sections.push('');

  sections.push('Remember: The goal is a working v1, not a perfect product. Focus on functionality first.');

  return sections.join('\n');
}

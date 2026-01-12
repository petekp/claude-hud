import { describe, it, expect } from 'vitest';
import { buildCreationPrompt } from '../../../src/project-creator/index.js';

describe('buildCreationPrompt', () => {
  it('should include project name and description', () => {
    const input = {
      name: 'test-cli',
      description: 'A CLI for testing things',
    };

    const prompt = buildCreationPrompt(input);

    expect(prompt).toContain('test-cli');
    expect(prompt).toContain('A CLI for testing things');
  });

  it('should request working implementation', () => {
    const input = {
      name: 'test-project',
      description: 'A test project',
    };

    const prompt = buildCreationPrompt(input);

    expect(prompt).toMatch(/working|functional|runnable/i);
    expect(prompt).toMatch(/v1|version 1|initial/i);
  });

  it('should specify language when provided', () => {
    const input = {
      name: 'rust-tool',
      description: 'A tool in Rust',
      preferences: {
        language: 'rust' as const,
      },
    };

    const prompt = buildCreationPrompt(input);

    expect(prompt).toMatch(/rust/i);
    expect(prompt).toMatch(/language|written in/i);
  });

  it('should specify framework when provided', () => {
    const input = {
      name: 'next-app',
      description: 'A web app',
      preferences: {
        language: 'typescript' as const,
        framework: 'Next.js',
      },
    };

    const prompt = buildCreationPrompt(input);

    expect(prompt).toContain('Next.js');
  });

  it('should request README with usage instructions', () => {
    const input = {
      name: 'test-project',
      description: 'A test project',
    };

    const prompt = buildCreationPrompt(input);

    expect(prompt).toMatch(/readme/i);
    expect(prompt).toMatch(/usage|how to (run|use)/i);
  });

  it('should emphasize working over perfect', () => {
    const input = {
      name: 'test-project',
      description: 'A test project',
    };

    const prompt = buildCreationPrompt(input);

    expect(prompt).toMatch(/working|functional/i);
    expect(prompt).toMatch(/not perfect|focus on|prioritize/i);
  });

  it('should request a way to run/test the project', () => {
    const input = {
      name: 'test-project',
      description: 'A test project',
    };

    const prompt = buildCreationPrompt(input);

    expect(prompt).toMatch(/run|start|test|execute/i);
  });

  it('should not include language section when not specified', () => {
    const input = {
      name: 'simple-project',
      description: 'A simple project',
    };

    const prompt = buildCreationPrompt(input);

    expect(prompt).not.toMatch(/written in|using \w+ as the language/i);
  });

  it('should handle TypeScript specifically', () => {
    const input = {
      name: 'ts-project',
      description: 'A TypeScript project',
      preferences: {
        language: 'typescript' as const,
      },
    };

    const prompt = buildCreationPrompt(input);

    expect(prompt).toMatch(/typescript/i);
  });
});

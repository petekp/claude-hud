import { describe, it, expect } from 'vitest';
import { generateClaudeMd } from '../../../src/project-creator/index.js';

describe('generateClaudeMd', () => {
  it('should include project name as title', () => {
    const input = {
      name: 'my-awesome-project',
      description: 'A tool for doing things',
    };

    const content = generateClaudeMd(input);

    expect(content).toContain('# my-awesome-project');
  });

  it('should include description in overview section', () => {
    const input = {
      name: 'test-project',
      description: 'A CLI tool that converts markdown to slides',
    };

    const content = generateClaudeMd(input);

    expect(content).toContain('A CLI tool that converts markdown to slides');
    expect(content).toMatch(/## (Overview|Description|About)/);
  });

  it('should include language preference if specified', () => {
    const input = {
      name: 'test-project',
      description: 'A test tool',
      preferences: {
        language: 'typescript' as const,
      },
    };

    const content = generateClaudeMd(input);

    expect(content).toContain('TypeScript');
  });

  it('should include framework preference if specified', () => {
    const input = {
      name: 'web-app',
      description: 'A web application',
      preferences: {
        language: 'typescript' as const,
        framework: 'Next.js',
      },
    };

    const content = generateClaudeMd(input);

    expect(content).toContain('Next.js');
  });

  it('should include status section indicating bootstrap', () => {
    const input = {
      name: 'new-project',
      description: 'Something new',
    };

    const content = generateClaudeMd(input);

    expect(content).toMatch(/## Status/);
    expect(content).toMatch(/bootstrap|v1|initial/i);
  });

  it('should be valid markdown', () => {
    const input = {
      name: 'markdown-test',
      description: 'Testing markdown output',
    };

    const content = generateClaudeMd(input);

    const headings = content.match(/^#+\s/gm) || [];
    expect(headings.length).toBeGreaterThan(0);

    const h1Index = content.indexOf('# ');
    const h2Index = content.indexOf('## ');
    expect(h1Index).toBeLessThan(h2Index);
  });

  it('should handle empty preferences gracefully', () => {
    const input = {
      name: 'test-project',
      description: 'A test project',
      preferences: {},
    };

    const content = generateClaudeMd(input);

    expect(content).toContain('# test-project');
    expect(content).toContain('A test project');
  });

  it('should not include tech stack section if no preferences', () => {
    const input = {
      name: 'simple-project',
      description: 'A simple project',
    };

    const content = generateClaudeMd(input);

    expect(content).not.toMatch(/## Tech Stack/);
  });
});

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { createProjectFromIdea } from '../../src/index.js';
import { rm, stat, readFile, readdir } from 'fs/promises';
import { join } from 'path';
import { execSync } from 'child_process';

const TEST_DIR = '/tmp/hud-e2e-tests';

const SKIP_E2E = process.env.SKIP_E2E === 'true' || !process.env.RUN_E2E;

describe.skipIf(SKIP_E2E)('E2E: Create Simple Project', () => {
  beforeEach(async () => {
    await rm(TEST_DIR, { recursive: true, force: true });
  });

  afterEach(async () => {
    await rm(TEST_DIR, { recursive: true, force: true });
  });

  it('should create a working Node.js CLI project', async () => {
    const request = {
      name: 'hello-cli',
      description: 'A simple CLI that prints a greeting with the provided name',
      location: TEST_DIR,
      preferences: {
        language: 'typescript' as const,
      },
    };

    const progressUpdates: any[] = [];

    const result = await createProjectFromIdea(request, (update) => {
      progressUpdates.push(update);
    });

    expect(result.success).toBe(true);
    expect(result.projectPath).toBe(join(TEST_DIR, 'hello-cli'));

    const files = await readdir(result.projectPath, { recursive: true });
    expect(files).toContain('package.json');
    expect(files.some(f => f.includes('src') || f.includes('index'))).toBe(true);

    const pkgJson = JSON.parse(
      await readFile(join(result.projectPath, 'package.json'), 'utf-8')
    );
    expect(pkgJson.name).toBe('hello-cli');

    const output = execSync('npm install && npm start -- World', {
      cwd: result.projectPath,
      encoding: 'utf-8',
    });
    expect(output).toMatch(/hello|world/i);

    expect(progressUpdates.length).toBeGreaterThan(0);
    expect(progressUpdates.some(u => u.phase === 'setup')).toBe(true);
    expect(progressUpdates.some(u => u.phase === 'building')).toBe(true);

    expect(result.sessionId).toBeDefined();
  }, 120000);

  it('should create CLAUDE.md with project context', async () => {
    const request = {
      name: 'documented-project',
      description: 'A project that does something specific and important',
      location: TEST_DIR,
    };

    const result = await createProjectFromIdea(request, () => {});

    const claudeMd = await readFile(
      join(result.projectPath, 'CLAUDE.md'),
      'utf-8'
    );
    expect(claudeMd).toContain('documented-project');
    expect(claudeMd).toContain('something specific');
  }, 120000);

  it('should handle creation failure gracefully', async () => {
    const request = {
      name: 'doomed-project',
      description: 'This will fail',
      location: '/root/no-permission',
    };

    const result = await createProjectFromIdea(request, () => {});

    expect(result.success).toBe(false);
    expect(result.error).toBeDefined();
  });
});

describe('createProjectFromIdea Unit Tests', () => {
  const TEST_UNIT_DIR = '/tmp/hud-unit-tests';

  beforeEach(async () => {
    await rm(TEST_UNIT_DIR, { recursive: true, force: true });
  });

  afterEach(async () => {
    await rm(TEST_UNIT_DIR, { recursive: true, force: true });
  });

  it('should create project directory', async () => {
    const request = {
      name: 'test-project',
      description: 'A test project',
      location: TEST_UNIT_DIR,
    };

    const result = await createProjectFromIdea(request, () => {}, { dryRun: true });

    expect(result.projectPath).toBe(join(TEST_UNIT_DIR, 'test-project'));
  });

  it('should fail if project directory cannot be created', async () => {
    const request = {
      name: '',
      description: 'Empty name project',
      location: TEST_UNIT_DIR,
    };

    const result = await createProjectFromIdea(request, () => {});

    expect(result.success).toBe(false);
    expect(result.error).toBeDefined();
  });

  it('should generate CLAUDE.md in project directory', async () => {
    const request = {
      name: 'md-test-project',
      description: 'Testing CLAUDE.md generation',
      location: TEST_UNIT_DIR,
      preferences: {
        language: 'typescript' as const,
      },
    };

    const result = await createProjectFromIdea(request, () => {}, { dryRun: true });

    expect(result.success).toBe(true);

    const claudeMdPath = join(result.projectPath, 'CLAUDE.md');
    const stats = await stat(claudeMdPath);
    expect(stats.isFile()).toBe(true);

    const content = await readFile(claudeMdPath, 'utf-8');
    expect(content).toContain('md-test-project');
    expect(content).toContain('TypeScript');
  });
});

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { createProjectDirectory } from '../../../src/project-creator/index.js';
import { rm, stat } from 'fs/promises';
import { join } from 'path';
import { homedir } from 'os';

const TEST_DIR = '/tmp/hud-test-projects';

describe('createProjectDirectory', () => {
  beforeEach(async () => {
    await rm(TEST_DIR, { recursive: true, force: true });
  });

  afterEach(async () => {
    await rm(TEST_DIR, { recursive: true, force: true });
  });

  it('should create directory at specified path', async () => {
    const projectName = 'my-test-project';
    const location = TEST_DIR;

    const result = await createProjectDirectory({
      name: projectName,
      location,
    });

    expect(result.success).toBe(true);
    expect(result.path).toBe(join(location, projectName));

    const stats = await stat(result.path);
    expect(stats.isDirectory()).toBe(true);
  });

  it('should fail if directory already exists', async () => {
    const projectName = 'existing-project';
    const location = TEST_DIR;
    await createProjectDirectory({ name: projectName, location });

    const result = await createProjectDirectory({
      name: projectName,
      location,
    });

    expect(result.success).toBe(false);
    expect(result.error).toContain('already exists');
  });

  it('should create nested directories if location does not exist', async () => {
    const projectName = 'nested-project';
    const location = join(TEST_DIR, 'deep', 'nested', 'path');

    const result = await createProjectDirectory({
      name: projectName,
      location,
    });

    expect(result.success).toBe(true);
    const stats = await stat(result.path);
    expect(stats.isDirectory()).toBe(true);
  });

  it('should sanitize project name for filesystem', async () => {
    const projectName = 'My Project! @#$%';
    const location = TEST_DIR;

    const result = await createProjectDirectory({
      name: projectName,
      location,
    });

    expect(result.success).toBe(true);
    expect(result.path).toBe(join(location, 'my-project'));
  });

  it('should return normalized absolute path', async () => {
    const projectName = 'test-project';
    const location = '~/Code';

    const result = await createProjectDirectory({
      name: projectName,
      location,
    });

    expect(result.path).not.toContain('~');
    expect(result.path).toMatch(new RegExp(`^${homedir()}`));

    await rm(result.path, { recursive: true, force: true });
  });

  it('should handle empty project name', async () => {
    const result = await createProjectDirectory({
      name: '',
      location: TEST_DIR,
    });

    expect(result.success).toBe(false);
    expect(result.error).toBeDefined();
  });

  it('should handle special characters correctly', async () => {
    const projectName = 'hello-world_v2.0';
    const location = TEST_DIR;

    const result = await createProjectDirectory({
      name: projectName,
      location,
    });

    expect(result.success).toBe(true);
    expect(result.path).toBe(join(location, 'hello-world_v2.0'));
  });
});

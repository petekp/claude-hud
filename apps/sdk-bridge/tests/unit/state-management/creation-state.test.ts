import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { CreationStateManager, CreationStatus } from '../../../src/state-management/index.js';
import { rm } from 'fs/promises';
import { join } from 'path';
import { tmpdir } from 'os';

const TEST_STATE_DIR = join(tmpdir(), 'hud-state-test');

describe('CreationStateManager', () => {
  let manager: CreationStateManager;

  beforeEach(() => {
    manager = new CreationStateManager(TEST_STATE_DIR);
  });

  afterEach(async () => {
    await rm(TEST_STATE_DIR, { recursive: true, force: true });
  });

  it('should create new creation with pending status', () => {
    const projectInfo = {
      name: 'test-project',
      path: '/tmp/test-project',
      description: 'A test',
    };

    const creation = manager.startCreation(projectInfo);

    expect(creation.status).toBe(CreationStatus.Pending);
    expect(creation.id).toBeDefined();
  });

  it('should transition to in-progress when SDK starts', () => {
    const creation = manager.startCreation({
      name: 'test',
      path: '/tmp/test',
      description: 'Test',
    });

    manager.markInProgress(creation.id, 'sess_123');

    const updated = manager.getCreation(creation.id);
    expect(updated?.status).toBe(CreationStatus.InProgress);
    expect(updated?.sessionId).toBe('sess_123');
  });

  it('should transition to completed on success', () => {
    const creation = manager.startCreation({
      name: 'test',
      path: '/tmp/test',
      description: 'Test',
    });
    manager.markInProgress(creation.id, 'sess_123');

    manager.markCompleted(creation.id);

    const updated = manager.getCreation(creation.id);
    expect(updated?.status).toBe(CreationStatus.Completed);
    expect(updated?.completedAt).toBeDefined();
  });

  it('should transition to failed on error', () => {
    const creation = manager.startCreation({
      name: 'test',
      path: '/tmp/test',
      description: 'Test',
    });
    manager.markInProgress(creation.id, 'sess_123');

    manager.markFailed(creation.id, 'SDK connection lost');

    const updated = manager.getCreation(creation.id);
    expect(updated?.status).toBe(CreationStatus.Failed);
    expect(updated?.error).toBe('SDK connection lost');
  });

  it('should list all active creations', () => {
    manager.startCreation({ name: 'p1', path: '/tmp/p1', description: 'P1' });
    manager.startCreation({ name: 'p2', path: '/tmp/p2', description: 'P2' });
    const completed = manager.startCreation({ name: 'p3', path: '/tmp/p3', description: 'P3' });
    manager.markInProgress(completed.id, 'sess');
    manager.markCompleted(completed.id);

    const active = manager.getActiveCreations();

    expect(active.length).toBe(2);
    expect(active.map(c => c.name)).toEqual(['p1', 'p2']);
  });

  it('should update progress information', () => {
    const creation = manager.startCreation({
      name: 'test',
      path: '/tmp/test',
      description: 'Test',
    });
    manager.markInProgress(creation.id, 'sess_123');

    manager.updateProgress(creation.id, {
      phase: 'building',
      message: 'Creating src/index.ts',
      percentComplete: 45,
    });

    const updated = manager.getCreation(creation.id);
    expect(updated?.progress?.phase).toBe('building');
    expect(updated?.progress?.percentComplete).toBe(45);
  });

  it('should persist state to disk', async () => {
    const creation = manager.startCreation({
      name: 'persistent',
      path: '/tmp/persistent',
      description: 'Test persistence',
    });

    await manager.persist();

    const newManager = new CreationStateManager(TEST_STATE_DIR);
    await newManager.load();
    const loaded = newManager.getCreation(creation.id);
    expect(loaded?.name).toBe('persistent');
  });

  it('should generate unique IDs for creations', () => {
    const creation1 = manager.startCreation({
      name: 'project1',
      path: '/tmp/project1',
      description: 'First project',
    });

    const creation2 = manager.startCreation({
      name: 'project2',
      path: '/tmp/project2',
      description: 'Second project',
    });

    expect(creation1.id).not.toBe(creation2.id);
  });

  it('should set createdAt timestamp', () => {
    const before = new Date();

    const creation = manager.startCreation({
      name: 'timestamped',
      path: '/tmp/timestamped',
      description: 'Test timestamps',
    });

    const after = new Date();

    expect(creation.createdAt.getTime()).toBeGreaterThanOrEqual(before.getTime());
    expect(creation.createdAt.getTime()).toBeLessThanOrEqual(after.getTime());
  });

  it('should return undefined for non-existent creation', () => {
    const result = manager.getCreation('non-existent-id');
    expect(result).toBeUndefined();
  });

  it('should include in-progress creations in active list', () => {
    const creation = manager.startCreation({
      name: 'in-progress',
      path: '/tmp/in-progress',
      description: 'Test',
    });
    manager.markInProgress(creation.id, 'sess_123');

    const active = manager.getActiveCreations();

    expect(active.length).toBe(1);
    expect(active[0].status).toBe(CreationStatus.InProgress);
  });

  it('should exclude failed creations from active list', () => {
    const creation = manager.startCreation({
      name: 'failed',
      path: '/tmp/failed',
      description: 'Test',
    });
    manager.markInProgress(creation.id, 'sess_123');
    manager.markFailed(creation.id, 'Error');

    const active = manager.getActiveCreations();

    expect(active.length).toBe(0);
  });
});

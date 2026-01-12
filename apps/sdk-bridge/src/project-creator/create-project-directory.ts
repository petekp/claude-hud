import { mkdir, stat } from 'fs/promises';
import { join, resolve } from 'path';
import { homedir } from 'os';
import type { CreateProjectInput, CreateProjectResult } from '../types.js';

function sanitizeProjectName(name: string): string {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9._-]/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '');
}

function expandPath(path: string): string {
  if (path.startsWith('~')) {
    return join(homedir(), path.slice(1));
  }
  return resolve(path);
}

export async function createProjectDirectory(
  input: CreateProjectInput
): Promise<CreateProjectResult> {
  const { name, location } = input;

  if (!name || name.trim() === '') {
    return {
      success: false,
      path: '',
      error: 'Project name cannot be empty',
    };
  }

  const sanitizedName = sanitizeProjectName(name);

  if (!sanitizedName) {
    return {
      success: false,
      path: '',
      error: 'Project name results in empty string after sanitization',
    };
  }

  const expandedLocation = expandPath(location);
  const projectPath = join(expandedLocation, sanitizedName);

  try {
    const stats = await stat(projectPath).catch(() => null);
    if (stats) {
      return {
        success: false,
        path: projectPath,
        error: `Directory already exists: ${projectPath}`,
      };
    }

    await mkdir(projectPath, { recursive: true });

    return {
      success: true,
      path: projectPath,
    };
  } catch (error) {
    return {
      success: false,
      path: projectPath,
      error: error instanceof Error ? error.message : 'Unknown error',
    };
  }
}

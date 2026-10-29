public enum DSHDesktopConnectorSelection {
  public static let script = #"""
    let output;
    try {
      output = process.stdout.write.bind(process.stdout);
      const discard = (_chunk, encoding, callback) => {
        if (typeof encoding === 'function') queueMicrotask(encoding);
        if (typeof callback === 'function') queueMicrotask(callback);
        return true;
      };
      process.stdout.write = discard;
      process.stderr.write = discard;

      const fs = await import('node:fs');
      const path = await import('node:path');
      const { pathToFileURL, fileURLToPath } = await import('node:url');
      const [entry, expected, profile] = process.argv.slice(1);
      const name = '@codex-bridge/dsh-desktop-connector';
      const equalPath = (left, right) => path.relative(left, right) === '';
      const realpath = value => fs.realpathSync.native(value);
      let boot, manager, atomic, anchor;

      const loadOfficialAPI = async () => {
        if (![entry, expected, profile].every(value => typeof value === 'string' && path.isAbsolute(value))) {
          return 'failed';
        }
        const runtime = path.resolve(path.dirname(entry), '../../../..');
        const packages = path.join(runtime, 'node_modules', '@deepseek-ai');
        const moduleURL = (...parts) => pathToFileURL(path.join(packages, ...parts)).href;
        try {
          [boot, manager, atomic] = await Promise.all([
            import(moduleURL('dsh-app-boot', 'lib', 'index.js')),
            import(moduleURL('dsh-plugin-manager', 'lib', 'types', 'operations.js')),
            import(moduleURL('dsh-atomic-write', 'lib', 'index.js')),
          ]);
        } catch (error) {
          if (['EACCES', 'EPERM', 'EIO'].includes(error?.code)) return 'failed';
          return 'unsupported';
        }
        const required = [
          [boot, 'readProfileManifest'], [boot, 'resolveBundleDir'],
          [boot, 'readProfileVersionExemptions'], [boot, 'evaluatePluginCompatibility'],
          [boot, 'bundlePatchPaths'], [boot, 'loadOverlayPatches'], [boot, 'composeEntries'],
          [manager, 'bundleManifest'], [manager, 'saveManifest'], [atomic, 'withFileLock'],
        ];
        if (required.some(([module, method]) => typeof module[method] !== 'function')) return 'unsupported';
        anchor = path.join(packages, 'dsh', 'package.json');
      };

      const checkRecordedRun = async () => {
        let contents;
        try {
          contents = await fs.promises.readFile(path.join(profile, '.plugin-manager', 'run.json'), 'utf8');
        } catch (error) {
          return error?.code === 'ENOENT' ? undefined : 'busy';
        }
        try {
          const { pid, grouped } = JSON.parse(contents);
          if (!Number.isSafeInteger(pid) || pid <= 0 || typeof grouped !== 'boolean') return 'busy';
          const target = process.platform !== 'win32' && grouped ? -pid : pid;
          try {
            process.kill(target, 0);
            return 'busy';
          } catch (error) {
            return error?.code === 'ESRCH' ? 'needs_install' : 'busy';
          }
        } catch {
          return 'busy';
        }
      };

      const checkInstallation = manifest => {
        const dependencies = manifest.dependencies;
        if (dependencies === undefined) return { status: 'needs_install' };
        if (!dependencies || typeof dependencies !== 'object' || Array.isArray(dependencies)) {
          return { status: 'unsupported' };
        }
        if (!Object.hasOwn(dependencies, name)) return { status: 'needs_install' };
        const spec = dependencies[name];
        if (typeof spec !== 'string') return { status: 'unsupported' };
        if (!spec.startsWith('link:') && !spec.startsWith('file:')) return { status: 'needs_install' };
        const ref = spec.slice(5);
        if (!ref) return { status: 'needs_install' };
        const expectedPath = realpath(expected);
        let dependencyPath;
        try {
          dependencyPath = realpath(spec.startsWith('file://') ? fileURLToPath(spec) : path.resolve(profile, ref));
        } catch (error) {
          return { status: error?.code === 'ENOENT' ? 'needs_install' : 'failed' };
        }
        if (!equalPath(expectedPath, dependencyPath)) return { status: 'needs_install' };
        let resolved;
        try {
          resolved = boot.resolveBundleDir('dsh', name, anchor, profile);
        } catch (error) {
          if (['ENOENT', 'MODULE_NOT_FOUND', 'ERR_MODULE_NOT_FOUND'].includes(error?.code)
              || (typeof error?.message === 'string' && error.message.startsWith('dsh: cannot resolve profile bundle '))) {
            return { status: 'needs_install' };
          }
          return { status: 'failed' };
        }
        let actualPath;
        try { actualPath = realpath(resolved); }
        catch (error) { return { status: error?.code === 'ENOENT' ? 'needs_install' : 'failed' }; }
        if (!equalPath(expectedPath, actualPath)) return { status: 'needs_install' };
        return { path: actualPath };
      };

      const verifyAndEnable = async (manifest, actualPath) => {
        const metadata = manager.bundleManifest(name, profile, anchor);
        if (!metadata || metadata.name !== name || !metadata.dsh?.bundle) return 'unsupported';
        const issue = boot.evaluatePluginCompatibility(metadata, boot.readProfileVersionExemptions(profile));
        if (issue !== undefined) {
          if (!issue || typeof issue !== 'object' || typeof issue.exempted !== 'boolean') return 'unsupported';
          if (!issue.exempted) return 'incompatible';
        }
        const files = boot.bundlePatchPaths(actualPath, metadata.dsh.bundle);
        if (!Array.isArray(files) || files.length !== 1 || typeof files[0] !== 'string') return 'unsupported';
        if (!equalPath(realpath(files[0]), realpath(path.join(actualPath, 'cordis.patch.yml')))) return 'failed';
        const patches = boot.loadOverlayPatches('dsh', files[0]);
        if (!Array.isArray(patches)) return 'unsupported';
        const entries = boot.composeEntries([patches]);
        if (!Array.isArray(entries)) return 'unsupported';
        const matches = entries.filter(value => value?.id === 'codex-bridge-dsh-desktop');
        const descriptor = path.join(path.dirname(path.dirname(expected)), 'endpoint.json');
        if (matches.length !== 1 || matches[0].name !== name || matches[0].disabled === true
            || typeof matches[0].config?.descriptorPath !== 'string'
            || !path.isAbsolute(matches[0].config.descriptorPath)
            || !equalPath(path.resolve(matches[0].config.descriptorPath), path.resolve(descriptor))) return 'failed';
        const dsh = manifest.dsh;
        if (dsh !== undefined && (!dsh || typeof dsh !== 'object' || Array.isArray(dsh))) return 'unsupported';
        const selection = dsh?.profile;
        if (selection !== undefined && (!selection || typeof selection !== 'object' || Array.isArray(selection))) return 'unsupported';
        const bundles = selection?.bundles === undefined ? [] : selection.bundles;
        if (!Array.isArray(bundles) || bundles.some(value => typeof value !== 'string')) return 'unsupported';
        if (bundles.includes(name)) return 'enabled';
        const updated = { ...manifest, dsh: { ...dsh, profile: { ...selection, bundles: [...bundles, name] } } };
        await manager.saveManifest(profile, updated);
        const saved = boot.readProfileManifest('dsh', profile);
        return JSON.stringify(saved) === JSON.stringify(updated) ? 'enabled' : 'failed';
      };

      const choose = async () => {
        const unavailable = await loadOfficialAPI();
        if (unavailable) return unavailable;
        try {
          if (!(await fs.promises.stat(profile)).isDirectory()) return 'failed';
        } catch (error) {
          return error?.code === 'ENOENT' ? 'needs_install' : 'failed';
        }
        const manifestPath = path.join(profile, 'package.json');
        try {
          return await atomic.withFileLock(manifestPath, async () => {
            const runStatus = await checkRecordedRun();
            if (runStatus) return runStatus;
            try {
              await fs.promises.lstat(manifestPath);
            } catch (error) {
              return error?.code === 'ENOENT' ? 'needs_install' : 'failed';
            }
            const manifest = boot.readProfileManifest('dsh', profile);
            const installation = checkInstallation(manifest);
            if (installation.status) return installation.status;
            return await verifyAndEnable(manifest, installation.path);
          }, { waitMs: 20000 });
        } catch (error) {
          if (typeof error?.message === 'string'
              && error.message.startsWith('atomic-write: timed out waiting for the writer lock at ')) return 'busy';
          return 'failed';
        }
      };

      let status;
      try { status = await choose(); }
      catch { status = 'failed'; }
      output(JSON.stringify({ status }) + '\n');
    } catch {
      try { (output ?? process.stdout.write.bind(process.stdout))('{"status":"failed"}\n'); } catch {}
    }
    """#
}

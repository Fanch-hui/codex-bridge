window.__ModuleLoader__.load({
  id: '@codex-bridge/dsh-desktop-connector',
  factory(require) {
    const React = require('react');
    const { useEffect, useState } = React;
    return {
      inject: ['connection', 'uiWorkspace', 'slots'],
      apply(ctx) {
        const listeners = new Set();
        let snapshot = { pending: [], grants: [], error: '' };
        let disposed = false;
        const controller = new AbortController();
        const notify = value => { snapshot = value; for (const listener of listeners) listener(value); };
        async function rpc(method, params = {}) {
          const result = await ctx.connection.rpc.call('/api', 'codex-bridge-desktop', { method, params }, controller.signal);
          if (!result.ok) throw new Error(result.error?.message ?? 'DSH Connector operation failed');
          return result.value;
        }
        async function refresh() {
          try { notify({ ...await rpc('state'), error: '' }); }
          catch (error) { if (!disposed) notify({ ...snapshot, error: error.message }); }
        }
        async function navigation() {
          while (!disposed) {
            try {
              const { commands } = await rpc('poll');
              for (const command of commands) {
                try {
                  ctx.uiWorkspace.openSession(command.sessionID);
                  await rpc('acknowledge', { id: command.id, ok: true });
                } catch (error) {
                  await rpc('acknowledge', { id: command.id, ok: false, message: error.message });
                }
              }
            } catch { if (!disposed) await new Promise(resolve => setTimeout(resolve, 2000)); }
          }
        }
        function PairingPanel() {
          const [state, setState] = useState(snapshot);
          const [busy, setBusy] = useState(false);
          useEffect(() => { listeners.add(setState); return () => listeners.delete(setState); }, []);
          async function action(method, params) {
            setBusy(true);
            try { await rpc(method, params); await refresh(); }
            catch (error) { notify({ ...snapshot, error: error.message }); }
            finally { setBusy(false); }
          }
          return React.createElement('section', { 'aria-label': 'Codex Bridge 连接', style: { padding: 16, border: '1px solid currentColor', borderRadius: 8 } },
            React.createElement('h3', null, 'Codex Bridge'),
            React.createElement('p', null, '确认码与 Bridge 一致后允许连接。配对后 Bridge 可管理已注册项目的原生会话。'),
            ...state.pending.map(item => React.createElement('div', { key: item.publicKey },
              React.createElement('p', null, `连接确认码：${item.code}`),
              React.createElement('code', null, item.fingerprint),
              React.createElement('button', { type: 'button', disabled: busy, onClick: () => action('approve', { publicKey: item.publicKey, code: item.code }) }, '允许连接'))),
            ...state.grants.map(item => React.createElement('div', { key: item.publicKey },
              React.createElement('p', null, `已连接：${item.fingerprint.slice(0, 16)}`),
              React.createElement('button', { type: 'button', disabled: busy, onClick: () => action('revoke', { publicKey: item.publicKey }) }, '撤销连接'))),
            state.error ? React.createElement('p', { role: 'alert' }, state.error) : null);
        }
        ctx.slots.inject('shell.overlay', () => ctx.slots.register({ name: 'shell.overlay', id: 'codex-bridge-pairing' }, () => {
          const [state, setState] = useState(snapshot);
          useEffect(() => { listeners.add(setState); return () => listeners.delete(setState); }, []);
          return state.pending.length ? React.createElement('div', { style: { position: 'fixed', right: 24, bottom: 24, zIndex: 1000, background: 'var(--color-background, Canvas)', maxWidth: 440 } }, React.createElement(PairingPanel)) : null;
        }));
        ctx.slots.inject('plugins.detail.section', () => ctx.slots.register({ name: 'plugins.detail.section', id: 'codex-bridge-connection' }, ({ subject }) => subject.pkg?.name === '@codex-bridge/dsh-desktop-connector' ? React.createElement(PairingPanel) : null));
        ctx.effect(() => {
          void refresh();
          void navigation();
          const timer = setInterval(() => { void refresh(); }, 2000);
          return () => { disposed = true; clearInterval(timer); controller.abort(); listeners.clear(); };
        });
      },
    };
  },
});

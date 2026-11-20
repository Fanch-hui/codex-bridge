import { SharedProviderAdapter } from './shared-provider-adapter.mjs';
import { CommunityProviderAdapter } from './community-provider-adapter.mjs';
import { imagePolicyFor } from './provider-image-policy.mjs';

export class SharedProviderRegistry {
  constructor(ctx, rpc) {
    this.ctx = ctx;
    this.rpc = rpc;
    this.groups = new Map();
    this.call = (action, payload, signal) => rpc.request('bridge/provider', { action, payload }, signal);
  }

  refresh() {
    const task = (this.pending ?? Promise.resolve()).then(() => this.readSnapshot());
    this.pending = task.catch(() => {});
    return task;
  }

  async readSnapshot() {
    const snapshot = await this.call('provider.snapshot', {});
    const next = new Map(snapshot.groups.map(group => [group.id, group]));
    for (const [id, current] of this.groups) {
      const group = next.get(id);
      if (!group) { current.handle(); this.groups.delete(id); continue; }
      const retained = group.routes.filter(route => current.adapter.routes.has(route.id));
      current.handle.replace(retained.map(route => route.id));
    }
    for (const group of snapshot.groups) {
      let current = this.groups.get(group.id);
      const imagePolicy = group.id === 'bridge.community' ? undefined : imagePolicyFor(this.ctx, group.imagePolicy);
      if (!current) {
        const adapter = group.id === 'bridge.community'
          ? new CommunityProviderAdapter(this.ctx, this.call, group.routes)
          : new SharedProviderAdapter({ group: group.id, routes: group.routes, call: this.call, imagePolicy,
            sessionHeader: id => this.ctx.sessions.get(id)?.header });
        current = { adapter, handle: this.ctx.llm.registerAdapter(group.routes.map(route => route.id), adapter) };
        this.groups.set(group.id, current);
      } else {
        current.adapter.setRoutes(group.routes);
        current.adapter.imagePolicy = imagePolicy;
        current.handle.replace(group.routes.map(route => route.id));
      }
    }
    if (this.directory) this.directory.replace(snapshot.configurableProviders);
    else this.directory = this.ctx.llm.registerConfigurableProviders(snapshot.configurableProviders);
    return { revision: snapshot.revision };
  }

  communityGroups() {
    const community = this.groups.get('bridge.community');
    if (!community) return [];
    return [...community.adapter.routes.values()].map(route => ({
      id: route.id, name: route.name,
      models: route.models.map(model => ({ id: model.id, name: model.name }))
    }));
  }

  dispose() {
    for (const { handle } of this.groups.values()) handle();
    this.groups.clear();
    this.directory?.();
  }
}

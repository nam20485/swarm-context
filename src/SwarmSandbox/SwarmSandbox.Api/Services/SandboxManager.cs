using Microsoft.Extensions.Options;
using SwarmSandbox.Api.Contracts;
using SwarmSandbox.Api.Data;
using SwarmSandbox.Api.Provisioning;

namespace SwarmSandbox.Api.Services;

/// <summary>Persists sandbox records and drives the provisioner for the API endpoints.</summary>
public sealed class SandboxManager(
    ISandboxStore store,
    ISandboxProvisioner provisioner,
    IOptions<SandboxOptions> options,
    TimeProvider timeProvider) : ISandboxManager
{
    public async Task<SandboxInfo> CreateSandboxAsync(SandboxRequest request, CancellationToken ct)
    {
        var branch = SandboxRequest.NormalizeBranch(request.Branch);
        var now = timeProvider.GetUtcNow();
        var record = new SandboxRecord
        {
            Id = Guid.NewGuid().ToString("N")[..12],
            State = SandboxState.Creating,
            Branch = branch,
            CreatedAt = now,
            ExpiresAt = now + options.Value.DefaultTtl,
        };
        await store.AddAsync(record, ct);

        try
        {
            var info = await provisioner.CreateSandboxAsync(new SandboxRequest(branch), ct);
            record.ContainerId = info.ContainerId;
            record.ContainerName = info.ContainerName;
            record.State = SandboxState.Running;
            await store.UpdateAsync(record, ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            record.State = SandboxState.Faulted;
            record.LastError = ex.Message;
            await store.UpdateAsync(record, ct);
            throw new SandboxProvisioningException(record.Id, ex);
        }

        return ToInfo(record);
    }

    public async Task<IReadOnlyList<SandboxInfo>> ListAsync(CancellationToken ct) =>
        (await store.ListAsync(ct)).Select(ToInfo).ToList();

    public async Task<SandboxStatus?> GetStatusAsync(string id, CancellationToken ct)
    {
        var record = await store.FindAsync(id, ct);
        if (record is null)
        {
            return null;
        }

        var info = ToInfo(record);

        // Records that never got a container (provisioning failed or is still in
        // flight) have no Docker identity to inspect: querying with the record id
        // would 404 and the not-found answer would overwrite the persisted Faulted
        // state and its error with Docker's "No such container" noise.
        if (string.IsNullOrEmpty(record.ContainerName) && string.IsNullOrEmpty(record.ContainerId))
        {
            return new SandboxStatus(info, record.LastError);
        }

        SandboxStatus? live = null;
        try
        {
            live = await provisioner.GetStatusAsync(ContainerIdentity(record), ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // Provisioner unreachable or container unknown: fall back to the persisted record.
        }

        if (live?.Info is { } liveInfo)
        {
            info = info with
            {
                State = liveInfo.State,
                ContainerId = OrDefault(liveInfo.ContainerId, info.ContainerId),
                ContainerName = OrDefault(liveInfo.ContainerName, info.ContainerName),
                // The persisted expiry is what the reaper enforces; the live value only fills a gap.
                ExpiresAt = info.ExpiresAt ?? liveInfo.ExpiresAt,
            };
        }

        return new SandboxStatus(info, live?.LastError ?? record.LastError);
    }

    public async Task<bool> DeleteAsync(string id, CancellationToken ct)
    {
        var record = await store.FindAsync(id, ct);
        if (record is null)
        {
            return false;
        }

        await provisioner.RemoveAsync(ContainerIdentity(record), ct);
        record.State = SandboxState.Removed;
        await store.UpdateAsync(record, ct);
        return true;
    }

    private static SandboxInfo ToInfo(SandboxRecord record) =>
        new(record.Id, record.ContainerId, record.State, record.CreatedAt, record.ExpiresAt, record.ContainerName);

    /// <summary>
    /// The identity the provisioner can actually address: the Docker container name,
    /// falling back to the recorded container id (and only then to the record id, for
    /// records that never got a container). Passing the record id itself made the
    /// provisioner act on a container that does not exist under that name.
    /// </summary>
    private static string ContainerIdentity(SandboxRecord record) =>
        !string.IsNullOrEmpty(record.ContainerName) ? record.ContainerName
        : !string.IsNullOrEmpty(record.ContainerId) ? record.ContainerId
        : record.Id;

    private static string OrDefault(string value, string fallback) =>
        string.IsNullOrEmpty(value) ? fallback : value;
}

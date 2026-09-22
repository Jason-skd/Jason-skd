//! GitHub REST and GraphQL integration for the profile generator.

const client = @import("github/client.zig");
const model = @import("github/model.zig");

pub const Client = client.Client;
pub const Config = client.Config;
pub const RetryConfig = client.RetryConfig;
pub const Transport = client.Transport;
pub const Header = client.Header;
pub const Request = client.Request;
pub const RawResponse = client.RawResponse;
pub const RateLimit = client.RateLimit;
pub const FailureKind = client.FailureKind;
pub const Failure = client.Failure;
pub const Result = client.Result;
pub const ProfileOptions = model.ProfileOptions;
pub const Access = model.Access;
pub const Contributions = model.Contributions;
pub const Repository = model.Repository;
pub const ContributedRepository = model.ContributedRepository;
pub const Profile = model.Profile;
pub const Organization = model.Organization;
pub const RepositoryMetadata = model.RepositoryMetadata;
pub const DataOperation = model.DataOperation;
pub const InvalidResponse = model.InvalidResponse;
pub const DataFailureCause = model.DataFailureCause;
pub const DataFailure = model.DataFailure;
pub const ProfileResult = model.ProfileResult;
pub const OrganizationResult = model.OrganizationResult;
pub const RepositoryMetadataResult = model.RepositoryMetadataResult;

test {
    _ = client;
    _ = @import("github/client_test.zig");
    _ = @import("github/model_test.zig");
    _ = @import("github/json.zig");
    _ = @import("github/redact.zig");
    _ = @import("github/retry.zig");
    _ = @import("github/transport.zig");
}

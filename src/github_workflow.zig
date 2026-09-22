//! GitHub-backed data collection workflows for stable profile domain values.

const metadata = @import("github_workflow/metadata.zig");
const model = @import("github_workflow/model.zig");
const profile = @import("github_workflow/profile.zig");

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
pub const fetchProfile = profile.fetchProfile;
pub const fetchOrganization = metadata.fetchOrganization;
pub const fetchRepositoryMetadata = metadata.fetchRepositoryMetadata;

test {
    _ = @import("github_workflow/model_test.zig");
    _ = profile;
    _ = metadata;
}

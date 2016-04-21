package Gitprep::Manager;
use Mojo::Base -base;

use Carp 'croak';
use Encode 'encode';
use File::Copy qw/move copy/;
use File::Path qw/mkpath rmtree/;
use File::Temp ();
use Fcntl ':flock';
use Carp 'croak';
use File::Copy qw/copy move/;
use File::Spec;
use Gitprep::Util;

has 'app';
has 'authorized_keys_file';

sub lock_rep {
  my ($self, $rep_info) = @_;
  
  my $git_dir = $rep_info->{git_dir};
  my $lock_file = "$git_dir/config";
  
  open my $lock_fh, '<', $lock_file
    or croak "Can't open lock file $lock_file: $!";
    
  flock $lock_fh, LOCK_EX
    or croak "Can't lock $lock_file";
  
  return $lock_fh;
}

sub check_merge_automatical {
  my ($self, $rep_info, $branch1, $branch2) = @_;
  
  # Create patch
  my @git_format_patch_cmd = $self->app->git->cmd(
    $rep_info,
    'format-patch',
    "$branch1..$branch2",
    "--stdout"
  );
  open my $git_format_patch_fh, '-|', @git_format_patch_cmd
    or Carp::croak "Can't execute git format-patch: @git_format_patch_cmd";
  my $patch_str = do { local $/; <$git_format_patch_fh> };
  
  # Write patch to file
  my $tmp_dir = File::Temp->newdir(DIR => $self->app->home->rel_file('/tmp'));
  my $patch_file = "$tmp_dir/test.patch";
  open my $patch_fh, '>', $patch_file
    or Carp::croak "Can't open patch file $patch_file: $!";
  print $patch_fh $patch_str;
  close $patch_fh;
  
  # Check if this patch can be applied
  my @git_apply_cmd = $self->app->git->cmd(
    $rep_info,
    'apply',
    $patch_file,
    '--check'
  );
  my $automatical = Gitprep::Util::run_command(@git_apply_cmd);
  
  return $automatical;
}

sub create_work_rep {
  my ($self, $user, $project) = @_;
  
  # Remote repository
  my $rep_info = $self->app->rep_info($user, $project);
  my $rep_git_dir = $rep_info->{git_dir};
  
  # Working repository
  my $work_rep_info = $self->app->work_rep_info($user, $project);
  my $work_tree = $work_rep_info->{work_tree};
  
  # Create working repository if it don't exist
  unless (-e $work_tree) {

    # git clone
    my @git_clone_cmd = ($self->app->git->bin, 'clone', $rep_git_dir, $work_tree);
    Gitprep::Util::run_command(@git_clone_cmd)
      or croak "Can't git clone: @git_clone_cmd";
    
    # Create temparary branch
    my $gitprep_tmp_branch_name = '__gitprep_tmp_branch__';
    my @git_branch_cmd = $self->app->git->cmd(
      $work_rep_info,
      'branch',
      $gitprep_tmp_branch_name,
    );
    Gitprep::Util::run_command(@git_branch_cmd)
      or Carp::croak "Can't execute git branch: @git_branch_cmd";

    # Set user name
    my @git_config_user_name = $self->app->git->cmd(
      $work_rep_info,
      'config',
      'user.name',
      $user
    );
    Gitprep::Util::run_command(@git_config_user_name)
      or croak "Can't execute git config: @git_config_user_name";
    
    # Set user mail
    my $user_mail = $self->app->dbi->model('user')->select('mail', where => {id => $user})->value;
    my @git_config_user_mail = $self->app->git->cmd(
      $work_rep_info,
      'config',
      'user.email',
      "$user_mail"
    );
    Gitprep::Util::run_command(@git_config_user_mail)
      or croak "Can't execute git config: @git_config_user_mail";
  }
}

sub admin_user {
  my $self = shift;
  
  # Admin user
  my $admin_user = $self->app->dbi->model('user')
    ->select(where => {admin => 1})->one;
  
  return $admin_user;
}

sub default_branch {
  my ($self, $user_id, $project_id, $default_branch) = @_;
  
  my $user_row_id = $self->api->get_user_row_id($user_id);
  
  # Set default branch
  my $dbi = $self->app->dbi;
  if (defined $default_branch) {
    $dbi->model('project')->update(
      {default_branch => $default_branch},
      where => {user => $user_row_id, id => $project_id}
    );
  }
  else {
    # Get default branch
    my $default_branch = $dbi->model('project')
      ->select('default_branch', where => {user => $user_row_id, id => $project_id})
      ->value;
    
    return $default_branch;
  }
}

sub fork_project {
  my ($self, $user_id, $original_user_id, $project_id) = @_;
  
  my $original_user_row_id = $self->api->get_user_row_id($original_user_id);
  
  # Fork project
  my $dbi = $self->app->dbi;
  my $error;
  eval {
    $dbi->connector->txn(sub {
      
      # Original project id
      my $project = $dbi->model('project')->select(
        ['row_id', 'private'],
        where => {user => $original_user_row_id, id => $project_id}
      )->one;
      
      use D;d [$original_user_row_id, $project_id, $project];
      
      # Create project
      eval {
        $self->_create_project(
          $user_id,
          $project_id,
          {
            original_project => $project->{row_id},
            private => $project->{private}
          }
        );
      };
      croak $error = $@ if $@;
      
      # Create repository
      eval {
        $self->_fork_rep($original_user_id, $project_id, $user_id, $project_id);
      };
      croak $error = $@ if $@;
    });
  };
  croak $error if $@;
}

sub is_admin {
  my ($self, $user_id) = @_;
  
  # Check admin
  my $is_admin = $self->app->dbi->model('user')
    ->select('admin', where => {id => $user_id})->value;
  
  return $is_admin;
}

sub is_private_project {
  my ($self, $user_id, $project_id) = @_;
  
  my $user_row_id = $self->api->get_user_row_id($user_id);
  
  # Is private
  my $private = $self->app->dbi->model('project')->select(
    'private', where => {user => $user_row_id, id => $project_id}
  )->value;
  
  return $private;
}

sub api { shift->app->gitprep_api }


sub member_projects {
  my ($self, $user_id, $project_id) = @_;
  
  my $user_row_id = $self->api->get_user_row_id($user_id);
  
  # DBI
  my $dbi = $self->app->dbi;
  
  # Original project id
  my $project_row_id = $dbi->model('project')
    ->select('row_id', where => {user => $user_row_id, id => $project_id})->value;
  
  # Members
  my $members = $dbi->model('project')->select(
    [
      {__MY__ => ['id']},
      {user => ['id']}
    ],
    where => {
      original_project => $project_row_id,
    },
    append => 'order by user.id, project.id'
  )->all;

  return $members;
}

sub create_project {
  my ($self, $user_id, $project_id, $opts) = @_;
  
  my $params = {};
  if ($opts->{private}) {
    $params->{private} = 1;
  }
  
  # Create project
  my $dbi = $self->app->dbi;
  my $error;
  eval {
    $dbi->connector->txn(sub {
      eval { $self->_create_project($user_id, $project_id, $params) };
      croak $error = $@ if $@;
      eval {$self->_create_rep($user_id, $project_id, $opts) };
      croak $error = $@ if $@;
    });
  };
  croak $error if $@;
}

sub create_user {
  my ($self, $user, $data) = @_;

  # Create user
  my $dbi = $self->app->dbi;
  my $error;
  eval {
    $dbi->connector->txn(sub {
      eval { $self->_create_db_user($user, $data) };
      croak $error = $@ if $@;
      eval {$self->_create_user_dir($user) };
      croak $error = $@ if $@;
    });
  };
  croak $error if $@;
}

sub delete_project {
  my ($self, $user, $project) = @_;
  
  # Delete project
  my $dbi = $self->app->dbi;
  my $error;
  eval {
    $dbi->connector->txn(sub {
      eval { $self->_delete_project($user, $project) };
      croak $error = $@ if $@;
      eval {$self->_delete_rep($user, $project) };
      croak $error = $@ if $@;
    });
  };
  croak $error if $@;
}

sub delete_user {
  my ($self, $user) = @_;
  
  # Delete user
  my $dbi = $self->app->dbi;
  my $error;
  my $count;
  eval {
    $dbi->connector->txn(sub {
      eval { $count = $self->_delete_db_user($user) };
      croak $error = $@ if $@;
      eval {$self->_delete_user_dir($user) };
      croak $error = $@ if $@;
    });
  };
  croak $error if $@;
  
  return $count;
}

sub original_project {
  my ($self, $user_id, $project_id) = @_;
  
  my $user_row_id = $self->api->get_user_row_id($user_id);
  
  # Original project id
  my $dbi = $self->app->dbi;
  my $original_project_row_id = $dbi->model('project')->select(
    'original_project',
    where => {user => $user_row_id, id => $project_id}
  )->value;
  
  croak "Original project don't eixsts." unless defined $original_project_row_id;
  
  # Original project
  my $original_project = $dbi->model('project')->select(
    [
      {__MY__ => '*'},
      {user => ['id']}
    ],
    where => {
      'project.row_id' => $original_project_row_id
    }
  )->one;
  
  return unless defined $original_project;
  
  return $original_project;
}

sub projects {
  my ($self, $user_id) = @_;
  
  my $user_row_id = $self->app->dbi->model('user')->select('row_id', where => {id => $user_id})->value;
  
  # Projects
  my $projects = $self->app->dbi->model('project')->select(
    where => {user => $user_row_id},
    append => 'order by id'
  )->all;
  
  return $projects;
}

sub users {
  my $self = shift;
  
  # Users
  my $users = $self->app->dbi->model('user')->select(
    where => [':admin{<>}',{admin => 1}],
    append => 'order by id'
  )->all;
  
  return $users;
}

sub rename_project {
  my ($self, $user, $project, $to_project) = @_;
  
  # Rename project
  my $git = $self->app->git;
  my $dbi = $self->app->dbi;
  my $error;
  eval {
    $dbi->connector->txn(sub {
      eval { $self->_rename_project($user, $project, $to_project) };
      croak $error = $@ if $@;
      eval { $self->_rename_rep($user, $project, $to_project) };
      croak $error = $@ if $@;
    });
  };
  croak $error if $error;
}

sub is_database_v1 {
  my $self = shift;
  
  # If project.user_id exists, that database is version 1
  my $user_id;
  eval { $user_id = $self->app->dbi->model('project')->select('user_id', append => 'limit 0, 1') };
  
  my $is_v1 = defined $user_id ? 1 : 0;
  
  return $is_v1;
}

=pod
  # If mail is empty, id is copied to mail for uniqueness
  my $user_ids = $dbi->select('id', table => 'user', where => {mail => ''})->values;
  for my $user_id (@$user_ids) {
    $dbi->update({mail => "$user_id\@gitprep.example"}, table => 'user', where => {id => $user_id});
  }
  
  # add unique to mail
  eval { $dbi->execute("create unique index user__mail on user(mail)") };
  my $created_user_mail_index = $dbi->execute("select * from sqlite_master where type = 'index' and name = 'user__mail'")->one;
  unless ($created_user_mail_index) {
    croak "Can't create user__mail index";
  }
=cut

sub setup_database {
  my $self = shift;
  
  my $dbi = $self->app->dbi;
  
  # Create user table
  eval {
    my $sql = <<"EOS";
create table user (
  row_id integer primary key autoincrement,
  id not null unique default '',
  email not null unique default ''
);
EOS
    $dbi->execute($sql);
  };

  # Create user columns
  my $user_columns = [
    "admin integer not null default 0",
    "password not null default ''",
    "salt not null default ''",
    "name not null default ''"
  ];
  for my $column (@$user_columns) {
    eval { $dbi->execute("alter table user add column $column") };
  }

  # Check user table
  eval { $dbi->select([qw/row_id id admin password salt email name/], table => 'user') };
  if ($@) {
    my $error = "Can't create user table properly: $@";
    $self->app->log->error($error);
    croak $error;
  }
  
  # Create project table
  eval {
    my $sql = <<"EOS";
create table project (
  row_id integer primary key autoincrement,
  user integer not null default 0,
  id not null,
  unique(user, id)
);
EOS
    $dbi->execute($sql);
  };
  
  # Create Project columns
  my $project_columns = [
    "default_branch not null default 'master'",
    "original_project integer not null default 0",
    "private integer not null default 0",
    "ignore_space_change integer not null default 0",
    "guess_encoding integer not null default ''"
  ];
  for my $column (@$project_columns) {
    eval { $dbi->execute("alter table project add column $column") };
  }

  # Check project table
  eval {
    $dbi->select(
      [qw/row_id user id default_branch original_project private ignore_space_change guess_encoding/],
      table => 'project'
    );
  };
  if ($@) {
    my $error = "Can't create project table properly: $@";
    $self->app->log->error($error);
    croak $error;
  }

  # Create ssh_public_key table
  eval {
    my $sql = <<"EOS";
create table ssh_public_key (
  row_id integer primary key autoincrement,
  key not null unique default ''
);
EOS
    $dbi->execute($sql);
  };

  # Create ssh_public_key columns
  my $ssh_public_key_columns = [
    "user integer not null default 0",
    "title not null default ''"
  ];
  for my $column (@$ssh_public_key_columns) {
    eval { $dbi->execute("alter table ssh_public_key add column $column") };
  }
  
  # Check ssh_public_key table
  eval { $dbi->select([qw/row_id user key title/], table => 'ssh_public_key') };
  if ($@) {
    my $error = "Can't create ssh_public_key table properly: $@";
    $self->app->log->error($error);
    croak $error;
  }

  # Create collaboration table
  eval {
    my $sql = <<"EOS";
create table collaboration (
  row_id integer primary key autoincrement,
  project integer not null default 0,
  collaborator integer not null default 0,
  unique(project, collaborator)
);
EOS
    $dbi->execute($sql);
  };
  
  # Check collaboration table
  eval { $dbi->select([qw/row_id project collaborator/], table => 'collaboration') };
  if ($@) {
    my $error = "Can't create collaboration table properly: $@";
    $self->app->log->error($error);
    croak $error;
  }

  # Create pull_request table
  eval {
    my $sql = <<"EOS";
create table pull_request (
  row_id integer primary key autoincrement,
  project integer not null default 0,
  branch1 not null default '',
  branch2 not null default '',
  unique(project, branch1, branch2)
);
EOS
    $dbi->execute($sql);
  };
  
  # Create pull_request columns
  my @pull_request_columns = (
    "title not null default ''",
    "open integer default 0",
    "open_time integer default 0",
    "open_user integer default 0"
  );
  for my $column (@pull_request_columns) {
    eval { $dbi->execute("alter table pull_request add column $column") };
  }

  # Check pull_request table
  eval { $dbi->select([qw/row_id project branch1 branch2 title open open_time open_user/], table => 'pull_request') };
  if ($@) {
    my $error = "Can't create pull_request table properly: $@";
    $self->app->log->error($error);
    croak $error;
  }
}

=pod
sub setup_database_v1 {
  my $self = shift;
  
  my $dbi = $self->app->dbi;
  
  # Create user table
  eval {
    my $sql = <<"EOS";
create table user (
  row_id integer primary key autoincrement,
  id not null unique default ''
);
EOS
    $dbi->execute($sql);
  };
  
  # Check mail column
  my $not_exists_user_mail;
  eval { $dbi->select('mail', table => 'user') };
  if ($@) {
    $not_exists_user_mail = 1;
  }

  # Create user columns
  my $user_columns = [
    "admin not null default '0'",
    "password not null default ''",
    "salt not null default ''",
    "mail not null default ''",
    "name not null default ''"
  ];
  for my $column (@$user_columns) {
    eval { $dbi->execute("alter table user add column $column") };
  }

  # Check user table
  eval { $dbi->select([qw/row_id id admin password salt mail name/], table => 'user') };
  if ($@) {
    my $error = "Can't create user table properly: $@";
    $self->app->log->error($error);
    croak $error;
  }
  
  # If mail is empty, id is copied to mail for uniqueness
  my $user_ids = $dbi->select('id', table => 'user', where => {mail => ''})->values;
  for my $user_id (@$user_ids) {
    $dbi->update({mail => "$user_id\@gitprep.example"}, table => 'user', where => {id => $user_id});
  }
  
  # add unique to mail
  eval { $dbi->execute("create unique index user__mail on user(mail)") };
  my $created_user_mail_index = $dbi->execute("select * from sqlite_master where type = 'index' and name = 'user__mail'")->one;
  unless ($created_user_mail_index) {
    croak "Can't create user__mail index";
  }
  
  # Create ssh_public_key table
  eval {
    my $sql = <<"EOS";
create table ssh_public_key (
  row_id integer primary key autoincrement,
  key not null unique default ''
);
EOS
    $dbi->execute($sql);
  };

  # Create ssh_public_key columns
  my $ssh_public_key_columns = [
    "user_id not null default ''",
    "title not null default ''"
  ];
  for my $column (@$ssh_public_key_columns) {
    eval { $dbi->execute("alter table ssh_public_key add column $column") };
  }
  
  # Check ssh_public_key table
  eval { $dbi->select([qw/row_id user_id key title/], table => 'ssh_public_key') };
  if ($@) {
    my $error = "Can't create ssh_public_key table properly: $@";
    $self->app->log->error($error);
    croak $error;
  }
  
  # Create project table
  eval {
    my $sql = <<"EOS";
create table project (
  row_id integer primary key autoincrement,
  user_id not null,
  name not null,
  unique(user_id, name)
);
EOS
    $dbi->execute($sql);
  };
  
  # Create Project columns
  my $project_columns = [
    "default_branch not null default 'master'",
    "original_user not null default ''",
    "original_project integer not null default 0",
    "private not null default 0",
    "ignore_space_change not null default 0",
    "guess_encoding not null default ''"
  ];
  for my $column (@$project_columns) {
    eval { $dbi->execute("alter table project add column $column") };
  }

  # Check project table
  eval {
    $dbi->select(
      [qw/default_branch original_user original_project private ignore_space_change guess_encoding/],
      table => 'project'
    );
  };
  if ($@) {
    my $error = "Can't create project table properly: $@";
    $self->app->log->error($error);
    croak $error;
  }

  # Create collaboration table
  eval {
    my $sql = <<"EOS";
create table collaboration (
  row_id integer primary key autoincrement,
  user_id not null default '',
  project_name not null default '',
  collaborator_id not null default '',
  unique(user_id, project_name, collaborator_id)
);
EOS
    $dbi->execute($sql);
  };
  
  # Check collaboration table
  eval { $dbi->select([qw/row_id user_id project_name collaborator_id/], table => 'collaboration') };
  if ($@) {
    my $error = "Can't create collaboration table properly: $@";
    $self->app->log->error($error);
    croak $error;
  }

  # Create number table
  eval {
    my $sql = <<"EOS";
create table number (
  row_id integer primary key autoincrement,
  key not null unique
);
EOS
    $dbi->execute($sql);
  };
  
  # Create number columns
  my $number_columns = [
    "value integer not null default '0'"
  ];
  for my $column (@$number_columns) {
    eval { $dbi->execute("alter table number add column $column") };
  }

  # Check number table
  eval { $dbi->select([qw/row_id key value/], table => 'number') };
  if ($@) {
    my $error = "Can't create number table properly: $@";
    $self->app->log->error($error);
    croak $error;
  }
  
  # Original project id number
  eval { $dbi->insert({key => 'original_project'}, table => 'number') };
  my $original_project = $dbi->select(
    'key',
    table => 'number',
    where => {key => 'original_project'}
  )->value;
  unless (defined $original_project) {
    my $error = "Can't create original_project row in number table";
    $self->app->log->error($error);
    croak $error;
  }

  # Create pull_request table
  eval {
    my $sql = <<"EOS";
create table pull_request (
  row_id integer primary key autoincrement,
  project integer not null default 0,
  branch1 not null default '',
  branch2 not null default '',
  unique(project, branch1, branch2)
);
EOS
    $dbi->execute($sql);
  };
  
  # Create pull_request columns
  my @pull_request_columns = (
    "title not null default ''",
    "message not null default ''",
    "open integer default 0",
    "open_time integer default 0",
    "open_user integer default 0"
  );
  for my $column (@pull_request_columns) {
    eval { $dbi->execute("alter table pull_request add column $column") };
  }

  # Check pull_request table
  eval { $dbi->select([qw/row_id project branch1 branch2 title message open open_time open_user/], table => 'pull_request') };
  if ($@) {
    my $error = "Can't create pull_request table properly: $@";
    $self->app->log->error($error);
    croak $error;
  }
}
=cut

sub update_authorized_keys_file {
  my $self = shift;

  my $authorized_keys_file = $self->authorized_keys_file;
  if (defined $authorized_keys_file) {
    
    # Lock file
    my $lock_file = $self->app->home->rel_file('lock/authorized_keys');
    open my $lock_fh, $lock_file
      or croak "Can't open lock file $lock_file";
    flock $lock_fh, LOCK_EX
      or croak "Can't lock $lock_file";
    
    # Create authorized_keys_file
    unless (-f $authorized_keys_file) {
      open my $fh, '>', $authorized_keys_file
        or croak "Can't create authorized_keys file: $authorized_keys_file";
      chmod 0600, $authorized_keys_file
        or croak "Can't chmod authorized_keys file: $authorized_keys_file";
    }
    
    # Parse file
    my $result = $self->parse_authorized_keys_file($authorized_keys_file);
    my $before_part = $result->{before_part};
    my $gitprep_part = $result->{gitprep_part};
    my $after_part = $result->{after_part};
    my $start_symbol = $result->{start_symbol};
    my $end_symbol = $result->{end_symbol};
    
    # Backup at first time
    if ($gitprep_part eq '') {
      # Backup original file
      my $to = "$authorized_keys_file.gitprep.original";
      unless (-f $to) {
        copy $authorized_keys_file, $to
          or croak "Can't copy $authorized_keys_file to $to";
      }
    }

    # Create public keys
    my $ssh_public_keys = $self->app->dbi->model('ssh_public_key')->select->all;
    my $ssh_public_keys_str = '';
    for my $key (@$ssh_public_keys) {
      my $ssh_public_key_str = 'command="' . $self->app->home->rel_file('script/gitprep-shell')
        . " $key->{user_id}\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $key->{key}";
      $ssh_public_keys_str .= "$ssh_public_key_str $key->{user_id}\n\n";
    }
    
    # Output tmp file
    my $output = "$before_part$start_symbol\n\n$ssh_public_keys_str$end_symbol$after_part";
    my $output_file = "$authorized_keys_file.gitprep.tmp";
    open my $out_fh, '>', $output_file
      or croak "Can't create authorized_keys tmp file $output_file";
    print $out_fh $output;
    close $out_fh
      or croak "Can't close authorized_keys tmp file $output_file";

    # Replace
    chmod 0600, $output_file
      or croak "Can't chmod authorized_keys tmp file: $output_file";
    move $output_file, $authorized_keys_file
      or croak "Can't replace $authorized_keys_file by $output_file";
  }
  else {
    croak qq/authorized_keys file "$authorized_keys_file" is not found./;
  }
}

sub parse_authorized_keys_file {
  my ($self, $file) = @_;
  
  my $start_symbol = "# gitprep start";
  my $end_symbol = "# gitprep end";
  
  # Parse
  open my $fh, '<', $file
    or croak "Can't open authorized_key file $file";
  my $start_symbol_count = 0;
  my $end_symbol_count = 0;
  my $before_part = '';
  my $gitprep_part = '';
  my $after_part = '';
  my $error_prefix = "authorized_keys file $file format error:";
  while (my $line = <$fh>) {
    if ($line =~ /^$start_symbol/) {
      if ($start_symbol_count > 0) {
        croak qq/$error_prefix "$start_symbol" is found more than one/;
      }
      else {
        if ($end_symbol_count > 0) {
          croak qq/$error_prefix "$end_symbol" is found before "$start_symbol"/;
        }
        else {
          $start_symbol_count++;
        }
      }
    }
    elsif ($line =~ /^$end_symbol/) {
      if ($end_symbol_count > 0) {
        croak qq/$error_prefix "$end_symbol" is found more than one/;
      }
      else {
        $end_symbol_count++;
      }
    }
    elsif ($start_symbol_count == 0 && $end_symbol_count == 0) {
      $before_part .= $line;
    }
    elsif ($start_symbol_count == 1 && $end_symbol_count == 0) {
      $gitprep_part .= $line;
    }
    elsif ($start_symbol_count == 1 && $end_symbol_count == 1) {
      $after_part .= $line;
    }
  }
  
  my $result = {
    start_symbol => $start_symbol,
    end_symbol => $end_symbol,
    before_part => $before_part,
    gitprep_part => $gitprep_part,
    after_part => $after_part
  };
  
  return $result;
}

sub _create_project {
  my ($self, $user_id, $project_id, $params) = @_;
  
  my $user_row_id = $self->api->get_user_row_id($user_id);
  $params ||= {};
  $params->{user} = $user_row_id;
  $params->{id} = $project_id;
  
  # Create project
  my $dbi = $self->app->dbi;
  $dbi->connector->txn(sub {
    $dbi->model('project')->insert($params);
  });
}

sub _create_rep {
  my ($self, $user, $project, $opts) = @_;
  
  # Create repository directory
  my $git = $self->app->git;
  
  my $rep_info = $self->app->rep_info($user, $project);
  my $rep_git_dir = $rep_info->{git_dir};
  
  mkdir $rep_git_dir
    or croak "Can't create directory $rep_git_dir: $!";
  
  eval {
    # Git init
    {
      my @git_init_cmd = $git->cmd($rep_info, 'init', '--bare');
      Gitprep::Util::run_command(@git_init_cmd)
        or croak  "Can't execute git init --bare:@git_init_cmd";
    }
    
    # Add git-daemon-export-ok
    {
      my $file = "$rep_git_dir/git-daemon-export-ok";
      open my $fh, '>', $file
        or croak "Can't create git-daemon-export-ok: $!"
    }
    
    # HTTP support
    my @git_update_server_info_cmd = $git->cmd(
      $rep_info,
      '--bare',
      'update-server-info'
    );
    Gitprep::Util::run_command(@git_update_server_info_cmd)
      or croak "Can't execute git --bare update-server-info";
    move("$rep_git_dir/hooks/post-update.sample", "$rep_git_dir/hooks/post-update")
      or croak "Can't move post-update";
    
    # Description
    my $description = $opts->{description};
    $description = '' unless defined $description;
    {
      my $file = "$rep_git_dir/description";
      open my $fh, '>', $file
        or croak "Can't open $file: $!";
      print $fh encode('UTF-8', $description)
        or croak "Can't write $file: $!";
      close $fh;
    }
    
    # Add README and commit
    if ($opts->{readme}) {
      # Create working directory
      my $home_tmp_dir = $self->app->home->rel_file('tmp');
      
      # Temp directory
      my $temp_dir =  File::Temp->newdir(DIR => $home_tmp_dir);
      
      # Working repository
      my $work_rep_work_tree = "$temp_dir/work";
      my $work_rep_git_dir = "$work_rep_work_tree/.git";
      my $work_rep_info = {
        work_tree => $work_rep_work_tree,
        git_dir => $work_rep_git_dir
      };
      
      mkdir $work_rep_work_tree
        or croak "Can't create directory $work_rep_work_tree: $!";
      
      # Git init
      my @git_init_cmd = $git->cmd($work_rep_info, 'init', '-q');
      Gitprep::Util::run_command(@git_init_cmd)
        or croak "Can't execute git init: @git_init_cmd";
      
      # Add README
      my $file = "$work_rep_work_tree/README.md";
      open my $readme_fh, '>', $file
        or croak "Can't create $file: $!";
      print $readme_fh "# $project\n";
      print $readme_fh "\n" . encode('UTF-8', $description) . "\n";
      close $readme_fh;
      
      my @git_add_cmd = $git->cmd(
        $work_rep_info,
        'add',
        'README.md'
      );
      
      Gitprep::Util::run_command(@git_add_cmd)
        or croak "Can't execute git add: @git_add_cmd";
      
      # Set user name
      my @git_config_user_name = $git->cmd(
        $work_rep_info,
        'config',
        'user.name',
        $user
      );
      Gitprep::Util::run_command(@git_config_user_name)
        or croak "Can't execute git config: @git_config_user_name";
      
      # Set user mail
      my $user_mail = $self->app->dbi->model('user')->select('mail', where => {id => $user})->value;
      my @git_config_user_mail = $git->cmd(
        $work_rep_info,
        'config',
        'user.email',
        "$user_mail"
      );
      Gitprep::Util::run_command(@git_config_user_mail)
        or croak "Can't execute git config: @git_config_user_mail";
      
      # Commit
      my @git_commit_cmd = $git->cmd(
        $work_rep_info,
        'commit',
        '-q',
        '-m',
        'first commit'
      );
      Gitprep::Util::run_command(@git_commit_cmd)
        or croak "Can't execute git commit: @git_commit_cmd";
      
      # Push
      {
        my @git_push_cmd = $git->cmd(
          $work_rep_info,
          'push',
          '-q',
          $rep_git_dir,
          'master'
        );
        # (This is bad, but --quiet option can't supress in old git)
        Gitprep::Util::run_command(@git_push_cmd)
          or croak "Can't execute git push: @git_push_cmd";
      }
    }
  };
  if (my $e = $@) {
    rmtree $rep_git_dir;
    croak $e;
  }
}

sub _create_db_user {
  my ($self, $user_id, $data) = @_;
  
  $data->{id} = $user_id;
  
  # Create database user
  $self->app->dbi->model('user')->insert($data);
}

sub _create_user_dir {
  my ($self, $user) = @_;
  
  # Create user directory
  my $rep_home = $self->app->rep_home;
  my $user_dir = "$rep_home/$user";
  mkpath $user_dir;
}

sub _delete_db_user {
  my ($self, $user_id) = @_;
  
  # Delete database user
  my $count = $self->app->dbi->model('user')->delete(where => {id => $user_id});
  
  return $count;
}

sub _delete_user_dir {
  my ($self, $user) = @_;
  
  # Delete user directory
  my $rep_home = $self->app->rep_home;
  my $user_dir = "$rep_home/$user";
  rmtree $user_dir;
}

sub _delete_project {
  my ($self, $user_id, $project_id) = @_;
  
  my $user_row_id = $self->api->get_user_row_id($user_id);
  
  # Delete project
  my $dbi = $self->app->dbi;
  $dbi->model('project')->delete(where => {user => $user_row_id, id => $project_id});
}

sub _delete_rep {
  my ($self, $user, $project) = @_;

  # Delete repository
  my $rep_home = $self->app->rep_home;
  croak "Can't remove repository. repository home is empty"
    if !defined $rep_home || $rep_home eq '';
  my $rep = "$rep_home/$user/$project.git";
  rmtree $rep;
  croak "Can't remove repository. repository is rest"
    if -e $rep;
}

sub exists_project {
  my ($self, $user_id, $project_id) = @_;
  
  my $user_row_id = $self->api->get_user_row_id($user_id);
  
  # Exists project
  my $dbi = $self->app->dbi;
  my $row = $dbi->model('project')->select(where => {user => $user_row_id, id => $project_id})->one;
  
  return $row ? 1 : 0;
}

sub exists_user {
  my ($self, $user_id) = @_;
  
  # Exists project
  my $row = $self->app->dbi->model('user')->select(where => {id => $user_id})->one;
  
  return $row ? 1 : 0;
}

sub _exists_rep {
  my ($self, $user, $project) = @_;
  
  # Exists repository
  my $rep_info = $self->app->rep_info($user, $project);
  my $rep_git_dir = $rep_info->{git_dir};
  
  return -e $rep_git_dir;
}

sub _fork_rep {
  my ($self, $user_id, $project_id, $to_user_id, $to_project_id) = @_;
  
  # Fork repository
  my $git = $self->app->git;
  
  my $rep_info = $self->app->rep_info($user_id, $project_id);
  my $rep_git_dir = $rep_info->{git_dir};
  
  my $to_rep_info = $self->app->rep_info($to_user_id, $to_project_id);
  my $to_rep_git_dir = $to_rep_info->{git_dir};

  my @cmd = (
    $git->bin,
    'clone',
    '-q',
    '--bare',
    $rep_git_dir,
    $to_rep_git_dir
  );
  Gitprep::Util::run_command(@cmd)
    or croak "Can't fork repository(_fork_rep): @cmd";
  
  # Copy description
  copy "$rep_git_dir/description", "$to_rep_git_dir/description"
    or croak "Can't copy description file(_fork_rep)";
}

sub _rename_project {
  my ($self, $user_id, $project_id, $renamed_project_id) = @_;
  
  my $user_row_id = $self->api->get_user_row_id($user_id);
  
  # Check arguments
  croak "Invalid parameters(_rename_project)"
    unless defined $user_id && defined $project_id && defined $renamed_project_id;
  
  # Rename project
  my $dbi = $self->app->dbi;
  $dbi->model('project')->update(
    {id => $renamed_project_id},
    where => {user => $user_row_id, id => $project_id}
  );
}

sub _rename_rep {
  my ($self, $user, $project, $renamed_project) = @_;
  
  # Check arguments
  croak "Invalid user name or project"
    unless defined $user && defined $project && defined $renamed_project;

  # Rename repository
  my $rep_info = $self->app->rep_info($user, $project);
  my $rep_git_dir = $rep_info->{git_dir};
  
  my $renamed_rep_info = $self->app->rep_info($user, $renamed_project);
  my $renamed_rep_git_dir = $renamed_rep_info->{git_dir};

  move($rep_git_dir, $renamed_rep_git_dir)
    or croak "Can't move $rep_git_dir to $renamed_rep_git_dir: $!";
}

1;

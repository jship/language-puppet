
node 'test' {
    $root_group = 'root'
  File {
    owner  => 'root',
    group  => $root_group,
    mode   => '0400',
    notify => Exec['mysqld-restart'],
  }

  file { '/lapin': ;}
}
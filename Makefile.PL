use inc::Module::Install;

name          ( 'CPAN-Processor'              );
abstract      ( 'Use PPI to process every perl file/module in CPAN' );
author        ( 'Adam Kennedy<cpan@ali.as>'   );
version_from  ( 'lib/CPAN/Processor.pm'       );
license       ( 'perl'                        );

requires      ( 'perl'             => '5.006' );
requires      ( 'List::Util'       => '1.11'  );
requires      ( 'File::Remove'     => '0.24'  );
requires      ( 'File::Find::Rule' => '0.27'  );
requires      ( 'IO::Zlib'         => '1.04'  );
requires      ( 'Archive::Tar'     => '1.22'  );
requires      ( 'PPI::Processor'   => '0.11'  );
requires      ( 'CPAN::Mini'       => '0.30'  );

build_requires( 'File::Spec'       => '0.82'  );
build_requires( 'Test::More'       => '0.47'  );

auto_install();

&WriteAll;

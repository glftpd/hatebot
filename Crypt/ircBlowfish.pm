package Crypt::ircBlowfish;

use 5.006001;
use strict;
use warnings;
use Crypt::Blowfish_PP;

require Exporter;

our @ISA = qw(Exporter);

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.

# This allows declaration	use ircBlowfish ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
our %EXPORT_TAGS = ( 'all' => [ qw(new encrypt decrypt set_key bytetoB64 B64tobyte) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(encrypt decrypt set_key bytetoB64 B64tobyte);

our $VERSION = '0.01';


my $key = "";

sub new {
	my $package = shift;
	return bless({}, $package);
}

sub decrypt {
	my $test = shift(@_);
	my $eText = $_[0];
	my $dText = "";

	my @charArray = split(//, $eText);
	my @stringArray = ();
	my $i = 0;
	my $k = 0;
	my $temp = "";
	foreach(@charArray)
	{
		$temp .= $charArray[$i];
		if($k == 11)
		{
			push(@stringArray, $temp);
			$k = -1;
			$temp = "";
		}
		$k++;
		$i++;
	}
	$i = 0;
	$temp = "";
	my $cipher = new Crypt::Blowfish_PP $key;
	foreach(@stringArray)
	{
		$temp = B64tobyte($stringArray[$i]);
		$dText .= $cipher->decrypt($temp);
		$i++;
	}
	return $dText;
}

sub encrypt {
	shift(@_);
	my $dText = $_[0];
	my $eText = "";

	if(defined($dText))
	{
		my @charArray = split(//, $dText);
		my $size = @charArray;
		my @stringArray = ();
		my $i = 0;
		my $k = 0;
		my $temp = "";
		foreach(@charArray)
		{
			$size--;
			$temp .= $charArray[$i];
			if($k == 7 || $size == 0)
			{
				if(length($temp) < 8)
				{
					my $j = 8 - length($temp);
					while($j > 0)
					{
						$temp .= "\0";
						$j--;
					}
				}
				push(@stringArray, $temp);
				$k = -1;
				$temp = "";
			}
			$k++;
			$i++;
		}

		$i = 0;
		$temp = "";
		my $cipher = new Crypt::Blowfish_PP $key;
		foreach(@stringArray)
		{
			if(length($stringArray[$i]) == 8)
			{
				$temp = $cipher->encrypt($stringArray[$i]);
				$eText .= bytetoB64($temp);
			}
			$i++;
		}
	}
	return $eText;
}

sub set_key {
	shift(@_);
	$key = $_[0];

	if(length($key) < 8)
	{
		my $keyLen = length($key);
		my $i = 8 / $keyLen;
		if($i=~/(\d+)\.\d+/)
		{
			$i = $1 + 1;
		}
		my $newkey = "";
		while($i > 0)
		{
			$newkey .= $key;
			$i--;
		}
		$key = $newkey;		
	}
}

sub bytetoB64 {
	my $ec = shift(@_);
	my $B64 = './0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
	my $dc = "";
	my $left = "";
	my $right = "";

	my $k = -1;

	while($k < (length($ec) - 1))
	{
		$k++;
		$left = (ord(substr($ec,$k,1)) << 24);
        	$k++;
	        $left += (ord(substr($ec,$k,1)) << 16);
        	$k++;
	        $left += (ord(substr($ec,$k,1)) << 8);
        	$k++;
	        $left += ord(substr($ec,$k,1));
		
	        $k++;
        	$right = (ord(substr($ec,$k,1)) << 24);
	        $k++;
        	$right += (ord(substr($ec,$k,1)) << 16);
	        $k++;
        	$right += (ord(substr($ec,$k,1)) << 8);
	        $k++;
        	$right += ord(substr($ec,$k,1));

		for(my $i = 0; $i < 6; $i++)
		{
			$dc .= substr($B64, $right & 0x3F,1);
			$right = $right >> 6;
		}
		for(my $i = 0; $i < 6; $i++)
		{
			$dc .= substr($B64, $left & 0x3F,1);
			$left = $left >> 6;
		}

      }
      return $dc;
}

sub B64tobyte
{
	my $ec = shift(@_);
	my $dc = "";
	my $B64 = './0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
	my $k = -1;
	my $right = "";
	my $left = "";

	while($k < (length($ec) - 1))
	{
		$right = 0;
		$left = 0;

        	for(my $i = 0; $i < 6; $i++)
		{
			$k++;
			my $temp = substr($ec, $k, 1);
			$right |= index($B64, $temp) << ($i * 6);
        	}
		for(my $i = 0; $i < 6; $i++)
		{
			$k++;
			my $temp = substr($ec, $k, 1);
			$left |= index($B64, $temp) << ($i * 6);
		}
		for(my $i = 0; $i < 4; $i++)
		{
			$dc .= chr(($left & (0xFF << ((3 - $i) * 8))) >> ((3 - $i) * 8));
		}
		for (my $i = 0; $i < 4; $i++)
		{
			$dc .= chr(($right & (0xFF << ((3 - $i) * 8))) >> ((3 - $i) * 8));
		}

      }

      return $dc;
}

1;
__END__

=head1 NAME

ircBlowfish.pm - Module to encode/decode Blowfish text being used in IRC.
This module is compatible with FiSH and <a href="http://mircryption.sourceforge.net">mircryption</a>.

=head1 DESCRIPTION

There are several encryption addons for irc clients, including <a href="http://mircryption.sourceforge.net">mircryption</a> and <a href="http://fish.sekure.us/">Fish</a>.
These addons use the <a href="http://www.schneier.com/blowfish.html">Blowfish</a> encryption algorithm and a non-standard base64, written in c++. 
You can identify Mircryption and Fish operation in a channel by the "mcps" and "+OK" prefixes in front of the encrypted text.

This Perl module implements encryption and decryption routines which are compatible with the irc encryption addons mentioned above.  Using this module you can decrypt text from a channel or encrypt text to be sent to the channel, in a manner compatible with mircryption and Fish.
It requires the Crypt::Blowfish module, but uses a non-standard custom base64 and padding routine.

=head1 SYNOPSIS

	use Crypt::ircBlowfish_PP;
	use strict;
	  
	
	my $key = 'test';

	my $blowfish = new Crypt::ircBlowfish_PP;
	$blowfish->set_key($key);
	my $eText = $blowfish->encrypt("Some text to encrypt here");
	print "eText: $eText\n";
	my $dText = $blowfish->decrypt($eText);
	print "dText: $dText\n";

=head1 METHODS 

=over 4

=item B<new>

  my $blowfish = new Crypt::ircBlowfish;

Instantiates the object.

=item B<set_key>

  $blowfish->set_key($key);

This sets the key to be used for encrypting and decrypting.

=item B<encrypt>

  my $eText = $blowfish->encrypt("Some text to encrypt here");

Returns the encrypted text of the given string.

=item B<decrypt>

  my $dText = $blowfish->decrypt($eText);

Returns the decrypted text of the given string.

=back

=head1 SEE ALSO

<a href="http://search.cpan.org/~dparis/Crypt-Blowfish-2.09/Blowfish.pm">Crypt::Blowfish</a>
It is required by this module if you dont already have it.

=head1 DISCLAIMER

I give no garuntee that I will keep this module updated.
Changes or alterations to FiSH or mircryption may cause this module to work improperly.

=head1 AUTHOR

Me @ max123469@yahoo.com

-- Special Thanks --
mouser @ irc.efnet.net
myBeer Group @ <a href="http://mybeer.org">http://mybeer.org</a> - For the Base64 example routine.

=head1 COPYRIGHT AND LICENSE

Module Copyright (c) 2005 Max.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=cut

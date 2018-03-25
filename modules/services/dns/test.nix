{ pkgs, ... }:

{
  name = "nixcloud-dns";

  nodes.server = { lib, ... }: {
    nixcloud.dns.zones = import ./example.nix;
    services.nsd.interfaces = lib.mkForce [];
    networking.firewall.allowedTCPPorts = [ 53 ];
    networking.firewall.allowedUDPPorts = [ 53 ];
  };

  nodes.client = { pkgs, lib, ... }: {
    environment.systemPackages = lib.singleton pkgs.dnsutils;
  };

  testScript = { nodes, ... }: let
    inherit (pkgs) lib;
    dnsLib = import ./lib { inherit lib; };
    inherit (nodes.server.config.nixcloud.dns) zoneList;
    inherit (nodes.server.config.networking) primaryIPAddress;

    mkDigCmd = { class, type, name }: let
      args = [
        "dig" "+noall" "+answer" "@${primaryIPAddress}" name type class
      ];
    in lib.concatMapStringsSep " " lib.escapeShellArg args;

    mkPerlStr = val: "'${lib.escape [ "\\" "'" ] (toString val)}'";

    mkDig = { domain, defaultTTL, records }: let
      domainName = dnsLib.joinDomainSimple domain;
      digRecord = record: let
        ttl = if record.ttl == null then defaultTTL else record.ttl;
        name = dnsLib.joinDomainAbsolute (record.relativeDomain ++ domain);
        digCmd = mkDigCmd { inherit name; inherit (record) type class; };
        command = "$client->succeed(${mkPerlStr digCmd})";

        mkCheck = perlVar: val: desc: ''
          push @errors,
            'record '.${mkPerlStr desc}." '${perlVar}' does not match '".
            ${mkPerlStr val}."'" if lc ${perlVar} ne lc ${mkPerlStr val};
        '';

        # We compare RDATA values by concatenating everything into a single
        # value without whitespace separation. The reason for this is that in
        # DNS it's not guaranteed that a value is going to end up in a single
        # field.
        simplifiedRdata = let
          mkField = val: let
            absDomain = dnsLib.joinDomainAbsolute (val.relative ++ domain);
          in if lib.isString val then val
             else if val ? autoSerial then "@serial@"
             else if val ? relative then absDomain
             else dnsLib.joinDomain val;
        in lib.concatMapStrings mkField record.rdata;

        hasAutoSerialPerl = let
          isTrue = lib.any (x: x ? autoSerial) record.rdata;
        in if isTrue then "1" else "0";

      in ''
        { my $output = ${command};
          chomp $output;
          my @records = split /\n/, $output;
          my $succeeded = 0;
          my @errors;
          foreach my $record (@records) {
            @errors = ();
            my ($name, $ttl, $class, $type, $rdata) = split /\s+/, $record, 5;
            ${mkCheck "\$name" name "owner name"}
            ${mkCheck "\$ttl" ttl "time-to-live"}
            ${mkCheck "\$class" record.class "class"}
            ${mkCheck "\$type" record.type "type"}
            my @rdataSplitted = $rdata =~ /(".*?"|\S+)/g;
            foreach my $i (0..$#rdataSplitted) {
              my $rd = $rdataSplitted[$i];
              # Special case: If the SOA serial is autogenerated, use @serial@
              # instead, so we don't get a mismatch.
              if ($i == 2 && $type eq 'SOA' && ${hasAutoSerialPerl} == 1) {
                $rdataSplitted[$i] = '@serial@';
              } elsif (substr($rd, 0, 1) eq '"') {
                $rdataSplitted[$i] = substr($rd, 1, -1);
                $rdataSplitted[$i] =~ s/\\(["\\])/$1/g;
              }
            }
            $rdata = join "", @rdataSplitted;
            ${mkCheck "\$rdata" simplifiedRdata "RDATA field"}
            $succeeded = 1 if !@errors;
          }
          die join(", ", @errors) if $succeeded == 0;
        }
      '';
    in ''
      subtest ${mkPerlStr "verify domain ${domainName}"}, sub {
        ${lib.concatMapStrings digRecord records}
      };
    '';

  in ''
    startAll;
    $server->waitForUnit('multi-user.target');
    $client->waitForUnit('network-online.target');

    ${lib.concatMapStrings mkDig zoneList}
  '';
}
# Installing

This document details how to install Hoff on your own server. I will be using
a server running CoreOS here, although the same steps should work for e.g.
Ubuntu 18.04.

The application consists of a single binary that opens a server at a configured
port, and then runs until it is killed. Log messages are written to stdout. This
makes the application work well with systemd. Furthermore, Hoff can be packaged
as a self-contained squashfs image for easy deployment and secure operation.

## Building a package

The squashfs image can be built with [Nix][nix]:

    $ nix build --out-link hoff.img

You can copy over `hoff.img` to your server. Alternatively, you can build the
binary only, and assemble your own package:

    $ stack build
    $ $(stack path --local-install-root)/bin/hoff

The systemd service file is in `package/hoff.service`.

## Installing the package

On the server, install the package:

    $ sudo dpkg --install hoff_0.0.0-1.deb

This will do several things:

 * Install the `hoff` binary in `/usr/bin`.
 * Create the `git` user under which the daemon will run.
 * Create an example config file at `/etc/hoff.json`.

Enable the daemon to start it automatically at boot, and start it now:

    $ sudo systemctl enable hoff
    $ sudo systemctl start hoff

Verify that everything is up and running:

    $ sudo systemctl status hoff

## Setting up the user

The systemd service file included runs Hoff as the `hoff` user, that we need to
create first:

    $ sudo useradd --system --user-group hoff

The application needs a key pair to connect to GitHub. Because the `hoff` system
user has no home directory, we will put it in `/etc/hoff` instead.

    $ sudo mkdir /etc/hoff
    $ sudo chown hoff:hoff /etc/hoff
    $ sudo --user hoff ssh-keygen -t ed25519 -f /etc/hoff/id_ed25519

Leave the passphrase empty to allow the key to be used without human
interaction. To tell SSH where the key is, we also create an SSH config file:

    $ echo "IdentityFile /etc/hoff/id_ed25519" | sudo tee --append /etc/hoff/ssh_config
    $ echo "CheckHostIP no"                    | sudo tee --append /etc/hoff/ssh_config

Here we also set `CheckHostIP no`, so SSH does not emit a warning when the IP
address of a host changes. Hoff ships with an `/etc/ssh/ssh_known_hosts` file
that contains GitHub's public key in the filesystem image, so there is no need
to accept any [fingerprints][fingerprints]. Because the `ssh_known_hosts` file
is readonly, we can *only* connect to GitHub, and only if the public key that we
baked into the image has not changed.

Finally, we need a GitHub account that will be used for fetching and pushing. I
recommend creating a separate account for this purpose. On GitHub, add the
public key to the new account. Paste the output of `sudo cat
/etc/hoff/id_ed25519.pub` into the key field under “SSH and GPG keys”.

## Adding a repostory

    $ sudo mkdir -p /var/lib/hoff /var/cache/hoff
    $ sudo chown hoff:hoff /var/lib/hoff /var/cache/hoff
    $ sudo -e /etc/hoff/config.json
    $ sudo cp hoff.service /etc/systemd/system
    $ sudo -e /etc/systemd/system/hoff.service
    $ sudo systemctl daemon-reload
    $ sudo systemctl enable hoff
    $ sudo systemctl start hoff

Then check if we are up and running:

    $ sudo journalctl --pager-end --unit hoff

## Adding a repository (old)

Hoff keeps a checkout of the repositories it manages. Currently it does not
handle the initial clone automatically. (TODO: automate.) Create a directory to
keep these checkouts, and also for the state files:

    $ sudo --user git mkdir /home/git/checkouts
    $ sudo --user git mkdir /home/git/state

I’ll be using the repository `ruuda/bogus` in this example. On GitHub, add the
bot account to this repository as a collaborator, to give it push access (and
pull access in the case of a private repository). Note that after adding the bot
as a collaborator, you need to accept the invitation from the bot account.
(TODO: automate this via the API.)

Now we can clone the repository on the server as the `git` user. I created a
subdirectory per GitHub owner to avoid collisions when the server manages
repositories for multiple owners.

    $ sudo --user git mkdir /home/git/state/ruuda
    $ sudo --user git mkdir /home/git/checkouts/ruuda
    $ cd $_
    $ sudo --user git HOME=/home/git git clone git@github.com:ruuda/bogus

Accept the unknown host prompt (do [validate the fingerprints][fingerprints]).

Finally, the daemon must be told about the repository in the config file:

    $ sudo --edit /etc/hoff.json

The meaning of the fields is as follows:

 * *Owner*: The GitHub user or organization that owns the repository. In my
   case `ruuda`.
 * *Repository*: The GitHub repository to manage. In my case `bogus`.
 * *Branch*: The branch to integrate changes into. `master` in most cases.
 * *TestBranch*: The branch that changes are pushed to to trigger a CI build.
   The application will force-push to this branch, so it should not be used for
   other purposes. I used `testing`.
 * *Checkout*: The full path to the checkout. `/home/git/checkouts/ruuda/bogus`
   in my case.
 * *StateFile*: The path to the file where the daemon saves its state, so it
   can remember the set of open pull requests across restarts. I use
   `/home/git/state/ruuda/bogus.json`. TODO: urge to back up this file regularly.

There are a few global options too:

 * *Secret*: The secret used to verify the authenticity of GitHub webhooks.
   You can run `head --bytes 32 /dev/urandom | base64` to generate a secure
   256-bit secret that doesn’t require any character to be escaped in the json
   file.
 * *Port*: The port at which the webhook server is exposed. The systemd unit
   ensures that the daemon has permissions to run on priviliged ports (such as
   80 and 443) without having to run as root.
 * *TLS*: Can be used to make the server serve https instead of insecure http.
   See the [TLS guide](tls.md) for more details.

Restart the daemon to pick up the new configuration, and verify that it started
properly:

    $ sudo systemctl restart hoff
    $ sudo systemctl status hoff

## Setting up webhooks

On GitHub, go to the repository settings and add a new webhook. The payload url
should be `http://yourserver.com/hook/github`, with content type
application/json. Enter the secret generated in the previous section, and select
the following events to be delivered:

 * *Pull request*, to make the daemon aware of new or closed pull requests.
 * *Issue comment*, to listen for LGTM stamps.
 * *Status*, to get updates on the build status from a linked CI service.

GitHub will deliver a ping event, and if everything is okay a green checkmark
will appear in the list of configured webhooks. On the server, we can see that
the webhook was received:

    $ sudo journalctl --pager-end --unit hoff
    > ...
    > Sep 04 21:37:41 hoffbuild hoff[2860]: [Debug] github loop received event: Ping

That’s it! You can now open a pull request and leave an LGTM comment to see the
application in action. Remember to also set up a CI service like Travis CI to
provide the build status updates.

TODO: Proper usage manual.

[fingerprints]: https://help.github.com/articles/github-s-ssh-key-fingerprints/
[nix]:          https://nixos.org/nix

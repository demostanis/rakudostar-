FROM docker.io/debian

RUN apt update -y
RUN apt install -y build-essential git cpanminus openssl libssl-dev zlib1g-dev
RUN cpanm --force Parallel::ForkManager \
	LWP::UserAgent LWP::Protocol::https \
	Archive::Tar Getopt::Std GnuPG::Interface \
	Time::Duration IPC::Run

COPY . /rakudostarplus

WORKDIR /rakudostarplus

CMD ./r*+.pl -y


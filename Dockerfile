FROM ruby:alpine3.11
COPY . /rubygems-mirror-s3
WORKDIR /rubygems-mirror-s3
RUN bundle install
RUN bundle exec gem mirror --help

FROM alpine:3.11
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apk/repositories
RUN apk update
RUN apk add git ruby-dev make gcc libc-dev
COPY . /rubygems-mirror-s3
RUN cd rubygems-mirror-s3
RUN gem install -V aws-sdk-s3 net-http-persistent json rake bundler webrick

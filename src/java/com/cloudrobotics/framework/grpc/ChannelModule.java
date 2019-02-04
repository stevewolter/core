// Copyright 2019 The Google Cloud Robotics Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package com.cloudrobotics.framework.grpc;

import dagger.Module;
import dagger.Provides;
import io.grpc.ManagedChannel;
import io.grpc.ManagedChannelBuilder;
import javax.inject.Named;

@Module
public class ChannelModule {
  @Provides
  ManagedChannel provideChannel(@Named("serviceName") String serviceName) {
    return ManagedChannelBuilder.forAddress(serviceName, 443).build();
  }
}
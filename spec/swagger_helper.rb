# frozen_string_literal: true

require 'rails_helper'

# Generates docs/api/openapi.yaml from the *_swagger_spec.rb request specs
# (ADR-0002, ADR-0030). Run `bundle exec rails rswag:specs:swaggerize` to
# regenerate; CI fails if the committed file drifts from that output.
#
# component_schemas below are the OpenAPI mirror of frontend/src/api/types.ts
# — every schema name here is re-exported under the identical name in that
# file, generated via openapi-typescript. Keep the two in step by hand when
# adding a schema; there is no tooling that checks the names match, only the
# frontend typecheck failing if they don't.
component_schemas = {
  MakingRow: {
    type: :object,
    properties: {
      first_name: { type: :string, nullable: true },
      pickup_code: { type: :string },
      items: { type: :array, items: { type: :string } },
      eta_seconds: { type: :number }
    },
    required: %w[first_name pickup_code items eta_seconds]
  },
  ReadyRow: {
    type: :object,
    properties: {
      first_name: { type: :string, nullable: true },
      pickup_code: { type: :string },
      ready_since_seconds: { type: :number },
      picked_up_seconds_ago: { type: :number, nullable: true }
    },
    required: %w[first_name pickup_code ready_since_seconds picked_up_seconds_ago]
  },
  BoardUpdate: {
    type: :object,
    properties: {
      type: { type: :string, enum: %w[board_update] },
      store_id: { type: :integer },
      making: { type: :array, items: { '$ref': '#/components/schemas/MakingRow' } },
      ready: { type: :array, items: { '$ref': '#/components/schemas/ReadyRow' } }
    },
    required: %w[type store_id making ready]
  },
  TimelineDrink: {
    type: :object,
    properties: {
      order_id: { type: :integer },
      drink_id: { type: :string },
      station: { type: :integer },
      started_at: { type: :number },
      finished_at: { type: :number, nullable: true },
      prep_seconds: { type: :number },
      remake: { type: :boolean },
      order_size: { type: :integer }
    },
    required: %w[order_id drink_id station started_at finished_at prep_seconds remake order_size]
  },
  SchedulerConfig: {
    type: :object,
    properties: {
      policy: { type: :string, enum: %w[drr fifo] },
      quantum: { type: :number },
      aging_enabled: { type: :boolean },
      aging_rate: { type: :number },
      cohesion_enabled: { type: :boolean },
      cohesion_boost: { type: :number },
      remake_multiplier: { type: :number },
      promise_buffer: { type: :number },
      quality_limit_seconds: { type: :number },
      eta_safety_factor: { type: :number }
    },
    required: %w[policy quantum aging_enabled aging_rate cohesion_enabled cohesion_boost
                 remake_multiplier promise_buffer quality_limit_seconds eta_safety_factor]
  },
  SchedulerConfigResponse: {
    type: :object,
    properties: {
      store_id: { type: :integer },
      scheduler_config: { '$ref': '#/components/schemas/SchedulerConfig' },
      editable: { type: :array, items: { type: :string } }
    },
    required: %w[store_id scheduler_config editable]
  },
  SimulationMetrics: {
    type: :object,
    properties: {
      orders: { type: :integer },
      drinks: { type: :integer },
      station_utilisation: { type: :number },
      reneged: { type: :integer },
      remakes: { type: :integer },
      wait_by_drink_cost: {
        type: :object,
        properties: {
          cheap: {
            type: :object,
            properties: { orders: { type: :integer }, p90: { type: :number } },
            required: %w[orders p90]
          },
          dear: {
            type: :object,
            properties: { orders: { type: :integer }, p90: { type: :number } },
            required: %w[orders p90]
          },
          comparable: { type: :boolean },
          ratio: { type: :number }
        },
        required: %w[cheap dear comparable ratio]
      },
      eta_accuracy: {
        type: :object,
        properties: {
          orders: { type: :integer },
          capped: { type: :integer },
          measurable: { type: :boolean },
          p50_abs: { type: :number },
          p90_abs: { type: :number },
          bias: { type: :number }
        },
        required: %w[orders capped measurable p50_abs p90_abs bias]
      },
      quality_breach_rate: { type: :number },
      quality_breach_rate_multi: { type: :number },
      wait_seconds: {
        type: :object,
        properties: { p50: { type: :number }, p90: { type: :number }, p99: { type: :number } },
        required: %w[p50 p90 p99]
      },
      by_size_class: {
        type: :object,
        additionalProperties: {
          type: :object,
          properties: {
            orders: { type: :integer },
            p90_meaningful: { type: :boolean },
            p50: { type: :number },
            p90: { type: :number },
            p99: { type: :number }
          },
          required: %w[orders p90_meaningful p50 p90 p99]
        }
      }
    },
    required: %w[orders drinks station_utilisation reneged remakes wait_by_drink_cost
                 eta_accuracy quality_breach_rate quality_breach_rate_multi wait_seconds by_size_class]
  },
  SimulationRun: {
    type: :object,
    properties: {
      seed: { type: :integer },
      stations: { type: :integer },
      window: {
        type: :object,
        properties: { from: { type: :number }, to: { type: :number } },
        required: %w[from to]
      },
      timeline: { type: :array, items: { '$ref': '#/components/schemas/TimelineDrink' } },
      order_spans: {
        type: :array,
        items: { type: :array, items: { type: :number }, minItems: 4, maxItems: 4 }
      },
      metrics: { '$ref': '#/components/schemas/SimulationMetrics' }
    },
    required: %w[seed stations window timeline order_spans metrics]
  },
  KdsItem: {
    type: :object,
    properties: {
      id: { type: :integer },
      label: { type: :string },
      status: { type: :string, enum: %w[queued in_progress finished] },
      prep_seconds: { type: :number },
      pickup_code: { type: :string },
      position: { type: :integer },
      order_size: { type: :integer },
      remake: { type: :boolean },
      quality_breach: { type: :boolean },
      station_id: { type: :integer, nullable: true },
      started_at: { type: :string, nullable: true }
    },
    required: %w[id label status prep_seconds pickup_code position order_size remake
                 quality_breach station_id started_at]
  },
  QueueUpdate: {
    type: :object,
    properties: {
      type: { type: :string, enum: %w[queue_update] },
      in_progress: { type: :array, items: { '$ref': '#/components/schemas/KdsItem' } },
      next_up: { type: :array, items: { '$ref': '#/components/schemas/KdsItem' } },
      depth: { type: :integer },
      oldest_waiting_seconds: { type: :number }
    },
    required: %w[type in_progress next_up depth oldest_waiting_seconds]
  },
  FailReason: {
    type: :string,
    enum: %w[spill wrong_order quality]
  },
  KdsSession: {
    type: :object,
    properties: {
      token: { type: :string },
      expires_in: { type: :number },
      barista: {
        type: :object,
        properties: { id: { type: :integer }, name: { type: :string } },
        required: %w[id name]
      },
      station: {
        type: :object,
        properties: { id: { type: :integer }, name: { type: :string } },
        required: %w[id name]
      },
      store: {
        type: :object,
        properties: { id: { type: :integer }, name: { type: :string } },
        required: %w[id name]
      }
    },
    required: %w[token expires_in barista station store]
  },
  MenuOption: {
    type: :object,
    properties: {
      id: { type: :integer },
      name: { type: :string },
      price_cents: { type: :integer },
      prep_seconds_delta: { type: :number }
    },
    required: %w[id name price_cents prep_seconds_delta]
  },
  OptionGroup: {
    type: :object,
    properties: {
      id: { type: :integer },
      name: { type: :string },
      min_select: { type: :integer },
      max_select: { type: :integer },
      options: { type: :array, items: { '$ref': '#/components/schemas/MenuOption' } }
    },
    required: %w[id name min_select max_select options]
  },
  MenuItem: {
    type: :object,
    properties: {
      id: { type: :integer },
      name: { type: :string },
      category: { type: :string },
      price_cents: { type: :integer },
      base_prep_seconds: { type: :number },
      option_groups: { type: :array, items: { '$ref': '#/components/schemas/OptionGroup' } }
    },
    required: %w[id name category price_cents base_prep_seconds option_groups]
  },
  Menu: {
    type: :object,
    properties: {
      items: { type: :array, items: { '$ref': '#/components/schemas/MenuItem' } }
    },
    required: %w[items]
  },
  OrderStatus: {
    type: :string,
    enum: %w[draft placed in_progress partially_ready ready picked_up abandoned cancelled]
  },
  DrinkStatus: {
    type: :string,
    enum: %w[queued in_progress finished failed cancelled]
  },
  PlacedOrderItem: {
    type: :object,
    properties: {
      id: { type: :integer },
      label: { type: :string },
      status: { '$ref': '#/components/schemas/DrinkStatus' },
      prep_seconds: { type: :number },
      sequence: { type: :integer },
      remake: { type: :boolean }
    },
    required: %w[id label status prep_seconds sequence remake]
  },
  PlacedOrder: {
    type: :object,
    properties: {
      pickup_code: { type: :string },
      status: { '$ref': '#/components/schemas/OrderStatus' },
      source: { type: :string, enum: %w[kiosk web] },
      customer_first_name: { type: :string, nullable: true },
      placed_at: { type: :string },
      promised_at: { type: :string, nullable: true },
      ready_at: { type: :string, nullable: true },
      total_cents: { type: :integer },
      quoted_wait_seconds: { type: :number },
      items: { type: :array, items: { '$ref': '#/components/schemas/PlacedOrderItem' } }
    },
    required: %w[pickup_code status source customer_first_name placed_at promised_at
                 ready_at total_cents quoted_wait_seconds items]
  },
  OrderUpdate: {
    type: :object,
    properties: {
      type: { type: :string, enum: %w[order_update] },
      pickup_code: { type: :string },
      status: { '$ref': '#/components/schemas/OrderStatus' },
      eta_seconds: { type: :number },
      items: {
        type: :array,
        items: {
          type: :object,
          properties: {
            id: { type: :integer },
            label: { type: :string },
            status: { '$ref': '#/components/schemas/DrinkStatus' }
          },
          required: %w[id label status]
        }
      }
    },
    required: %w[type pickup_code status eta_seconds items]
  },
  AdminUser: {
    type: :object,
    properties: { email: { type: :string } },
    required: %w[email]
  },
  # Not re-exported in frontend/src/api/types.ts — `Health` is defined locally in
  # frontend/src/order/useHealth.ts, not part of the shared shim. Documented here
  # anyway since it's a real endpoint response.
  Health: {
    type: :object,
    properties: {
      accepting_orders: { type: :boolean },
      store_name: { type: :string },
      server_time: { type: :string }
    },
    required: %w[accepting_orders store_name server_time]
  },
  # Not re-exported in types.ts — GET /admin/prep_time_stats has no frontend
  # consumer yet. Documented anyway since it's a real, shipped endpoint.
  PrepTimeStatItem: {
    type: :object,
    properties: {
      menu_item_id: { type: :integer },
      name: { type: :string },
      seeded_prep_seconds: { type: :number },
      ewma_seconds: { type: :number, nullable: true },
      ewma_variance: { type: :number, nullable: true },
      sample_count: { type: :integer },
      confident: { type: :boolean },
      minimum_samples: { type: :integer }
    },
    required: %w[menu_item_id name seeded_prep_seconds ewma_seconds ewma_variance
                 sample_count confident minimum_samples]
  },
  PrepTimeStats: {
    type: :object,
    properties: {
      items: { type: :array, items: { '$ref': '#/components/schemas/PrepTimeStatItem' } }
    },
    required: %w[items]
  },
  AblationArm: {
    type: :object,
    properties: {
      id: { type: :string },
      kind: { type: :string, enum: %w[control rung bound] },
      label: { type: :string },
      blurb: { type: :string },
      arrived: { type: :integer },
      metrics: { '$ref': '#/components/schemas/SimulationMetrics' }
    },
    required: %w[id kind label blurb arrived metrics]
  },
  Ablation: {
    type: :object,
    properties: {
      seed: { type: :integer },
      seeds: { type: :integer },
      stations: { type: :integer },
      demand_multiplier: { type: :number },
      quantum: { type: :number, nullable: true },
      arms: { type: :array, items: { '$ref': '#/components/schemas/AblationArm' } }
    },
    required: %w[seed seeds stations demand_multiplier quantum arms]
  },
  QuantumSweepPoint: {
    type: :object,
    properties: {
      quantum: { type: :number },
      arrived: { type: :integer },
      metrics: { '$ref': '#/components/schemas/SimulationMetrics' }
    },
    required: %w[quantum arrived metrics]
  },
  QuantumSweep: {
    type: :object,
    properties: {
      seed: { type: :integer },
      seeds: { type: :integer },
      stations: { type: :integer },
      demand_multiplier: { type: :number },
      points: { type: :array, items: { '$ref': '#/components/schemas/QuantumSweepPoint' } }
    },
    required: %w[seed seeds stations demand_multiplier points]
  },
  StaffingCurveHour: {
    type: :object,
    properties: {
      hour: { type: :integer },
      stations: { type: :integer },
      achieved: { type: :boolean },
      p90: { type: :number },
      orders: { type: :integer },
      p90_meaningful: { type: :boolean }
    },
    required: %w[hour stations achieved p90 orders p90_meaningful]
  },
  StaffingCurve: {
    type: :object,
    properties: {
      seed: { type: :integer },
      seeds: { type: :integer },
      demand_multiplier: { type: :number },
      target_seconds: { type: :number },
      hours: { type: :array, items: { '$ref': '#/components/schemas/StaffingCurveHour' } }
    },
    required: %w[seed seeds demand_multiplier target_seconds hours]
  },
  BreakingPointPoint: {
    type: :object,
    properties: {
      demand_multiplier: { type: :number },
      arrived: { type: :integer },
      metrics: { '$ref': '#/components/schemas/SimulationMetrics' }
    },
    required: %w[demand_multiplier arrived metrics]
  },
  BreakingPoint: {
    type: :object,
    properties: {
      seed: { type: :integer },
      seeds: { type: :integer },
      stations: { type: :integer },
      target_seconds: { type: :number },
      points: { type: :array, items: { '$ref': '#/components/schemas/BreakingPointPoint' } },
      capacity: { type: :number, nullable: true }
    },
    required: %w[seed seeds stations target_seconds points capacity]
  }
}.freeze

RSpec.configure do |config|
  config.openapi_root = Rails.root.join('docs', 'api').to_s

  config.openapi_specs = {
    'openapi.yaml' => {
      openapi: '3.0.3',
      info: {
        title: 'Boba Shop API',
        version: 'v1',
        description: 'The shared API surface (DESIGN.md §9.1) for the kiosk/web ordering ' \
                      'app, the kitchen display, the customer board, and the admin dashboard. ' \
                      'Generated from spec/requests/api/v1/*_swagger_spec.rb — never hand-edit.'
      },
      paths: {},
      components: {
        schemas: component_schemas,
        securitySchemes: {
          # KDS station token (§13.3) — issued by POST /kds/session, sent as
          # `Authorization: Bearer <token>`.
          kds_token: { type: :http, scheme: :bearer },
          # Admin cookie session (§13.4, ADR-0006) — SameSite=Strict, issued by
          # POST /admin/session. No bearer token, no CSRF token by design.
          admin_session: { type: :apiKey, in: :cookie, name: '_boba_gals_admin' }
        }
      },
      servers: [
        { url: 'http://localhost:3000', description: 'Local development' }
      ]
    }
  }

  config.openapi_format = :yaml
end
